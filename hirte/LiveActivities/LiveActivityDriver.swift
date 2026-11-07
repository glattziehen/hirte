import ActivityKit
import Foundation

/// A narrow platform boundary lets lifecycle tests run without requesting a system activity.
@MainActor
protocol LiveActivityDriver: AnyObject {
    var isAvailable: Bool { get }
    func start(id: UUID, state: AgentActivityAttributes.ContentState) throws
    /// Takes over this follow's activity from an earlier run, ending any other. Returns its state,
    /// or nil if iOS no longer shows it as running: an ended or dismissed one never comes back.
    func restore(id: UUID) -> AgentActivityAttributes.ContentState?
    func update(_ state: AgentActivityAttributes.ContentState) async
    func end(_ state: AgentActivityAttributes.ContentState?, seconds: TimeInterval) async
    func removeAll() async
    func observeDismissal(_ dismissed: @escaping @MainActor () -> Void)
    /// Reports the person's changes to the Live Activities switch in iOS Settings.
    func observeAvailability(_ changed: @escaping @MainActor (Bool) -> Void)
}

@MainActor
final class ActivityKitDriver: LiveActivityDriver {
    private var activity: Activity<AgentActivityAttributes>?
    private var observer: Task<Void, Never>?
    private var availabilityObserver: Task<Void, Never>?

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(id: UUID, state: AgentActivityAttributes.ContentState) throws {
        activity = try Activity.request(
            attributes: AgentActivityAttributes(followID: id),
            content: content(state), pushType: nil)
    }

    func restore(id: UUID) -> AgentActivityAttributes.ContentState? {
        let activities = Activity<AgentActivityAttributes>.activities
        guard let found = activities.first(where: { $0.attributes.followID == id }),
              found.activityState == .active || found.activityState == .stale else { return nil }
        activity = found
        for other in activities where other.id != found.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        return found.content.state
    }

    func update(_ state: AgentActivityAttributes.ContentState) async {
        await activity?.update(content(state))
    }

    func end(_ state: AgentActivityAttributes.ContentState?, seconds: TimeInterval) async {
        observer?.cancel()
        observer = nil
        // Retain the ended handle until replacement/opt-out so its remaining UI can be removed.
        await activity?.end(state.map(content), dismissalPolicy: seconds > 0 ? .after(.now + seconds) : .immediate)
    }

    func removeAll() async {
        observer?.cancel()
        observer = nil
        let known = activity
        activity = nil
        var activities = Activity<AgentActivityAttributes>.activities
        if let known, !activities.contains(where: { $0.id == known.id }) { activities.append(known) }
        for old in activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
    }

    func observeDismissal(_ dismissed: @escaping @MainActor () -> Void) {
        observer?.cancel()
        guard let activity else { return }
        observer = Task {
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed || state == .ended {
                    dismissed()
                    return
                }
            }
        }
    }

    func observeAvailability(_ changed: @escaping @MainActor (Bool) -> Void) {
        availabilityObserver?.cancel()
        availabilityObserver = Task {
            for await available in ActivityAuthorizationInfo().activityEnablementUpdates {
                changed(available)
            }
        }
    }

    private func content(_ state: AgentActivityAttributes.ContentState) -> ActivityContent<AgentActivityAttributes.ContentState> {
        // A short lease also covers a crash or suspension before the explicit stale update.
        ActivityContent(state: state, staleDate: state.isLastKnown ? .now : state.asOf + 45)
    }
}

/// What to tell the person when `Activity.request` fails. Only an unexpected failure carries its
/// code: that's what a report from a device has to say, and it holds nothing about the task.
func followStartFailure(_ error: any Error) -> String {
    guard let error = error as? ActivityAuthorizationError else {
        return "The Lock Screen activity could not start. (\(error.localizedDescription))"
    }
    switch error {
    case .denied: return "Live Activities are off for Hirte. Allow them in iOS Settings."
    case .globalMaximumExceeded, .targetMaximumExceeded:
        return "Too many Live Activities are running. End one and try again."
    case .visibility: return "Hirte has to be on screen to start following. Open it and try again."
    case .unsupported, .unsupportedTarget: return "This device or build can't show Live Activities."
    case .unentitled: return "This build of Hirte isn't allowed to start Live Activities."
    default: return "iOS could not start the Lock Screen activity. Try again. (ActivityKit: \(String(describing: error)))"
    }
}
