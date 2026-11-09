import Foundation
import HerdrKit
import Observation
import SwiftUI
import UIKit

/// One explicit follow across all windows. No remote identity is put in ActivityKit or the URL.
@MainActor @Observable
final class FollowController {
    static let shared = FollowController()
    static let enabledKey = "liveActivity.enabled"
    static let titleKey = "liveActivity.showTitle"
    static let followKey = "liveActivity.follow"

    /// Kept on this device so the follow outlives a relaunch. Identity only, no terminal content.
    private(set) var selection: FollowTask? { didSet { persist() } }
    private(set) var lastState: AgentActivityAttributes.ContentState?
    private(set) var errorMessage: String?
    /// iOS accepted this follow's activity and nothing confirmed it to the person yet.
    private(set) var unconfirmedStart: UUID?
    /// The person's Live Activities switch in iOS Settings, kept here so that screens follow it.
    private(set) var isAvailable: Bool
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if !enabled { stop() }
        }
    }
    var showTitle: Bool {
        didSet {
            defaults.set(showTitle, forKey: Self.titleKey)
            // Removing permission must remove even an already-ended title from the Lock Screen.
            stop()
        }
    }

    private let defaults: UserDefaults
    private let driver: any LiveActivityDriver
    private let beginBackgroundTask: (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
    private weak var source: HostSession?
    private var completed: FollowTask?
    private var completedPhase: AgentActivityAttributes.ContentState.Phase?
    private var activeWindows: Set<UUID> = []
    private var routes: [UUID: FollowTask] = [:]
    private var operation: Task<Void, Never>?
    private var prepared = false
    private var observedTurn: UInt64? { didSet { if observedTurn != oldValue { persist() } } }
    private var needsReconciliation = false

    init(
        defaults: UserDefaults = .standard, driver: (any LiveActivityDriver)? = nil,
        beginBackgroundTask: @escaping (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: "Mark activity last known", expirationHandler: $0)
        },
        endBackgroundTask: @escaping (UIBackgroundTaskIdentifier) -> Void = {
            UIApplication.shared.endBackgroundTask($0)
        }
    ) {
        self.defaults = defaults
        let driver = driver ?? ActivityKitDriver()
        self.driver = driver
        isAvailable = driver.isAvailable
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        enabled = defaults.bool(forKey: Self.enabledKey)
        showTitle = defaults.bool(forKey: Self.titleKey)
    }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        driver.observeAvailability { [weak self] in self?.availabilityChanged($0) }
        if let stored = storedFollow(), let state = driver.restore(id: stored.task.followID) {
            selection = stored.task
            observedTurn = stored.observedTurn
            lastState = state
            // Whatever happened in between, it isn't known to be the same task until `received` checks.
            needsReconciliation = true
            routes[stored.task.followID] = stored.task
            driver.observeDismissal(dismissed(stored.task))
        } else {
            defaults.removeObject(forKey: Self.followKey)
            enqueue { await self.driver.removeAll() }
        }
    }

    private struct StoredFollow: Codable {
        let task: FollowTask
        let observedTurn: UInt64?
    }

    private func persist() {
        if let selection, let data = try? JSONEncoder().encode(StoredFollow(task: selection, observedTurn: observedTurn)) {
            defaults.set(data, forKey: Self.followKey)
        } else {
            defaults.removeObject(forKey: Self.followKey)
        }
    }

    private func storedFollow() -> StoredFollow? {
        guard enabled, isAvailable, let data = defaults.data(forKey: Self.followKey),
              let stored = try? JSONDecoder().decode(StoredFollow.self, from: data),
              Date.now.timeIntervalSince(stored.task.startedAt) < 8 * 60 * 60 else { return nil }
        return stored
    }

    private func dismissed(_ task: FollowTask) -> @MainActor () -> Void {
        { [weak self] in
            guard let self, self.selection?.followID == task.followID else { return }
            // Only iOS can do this while Hirte is on screen: nobody can swipe it away from here.
            if !self.activeWindows.isEmpty, Date.now.timeIntervalSince(task.startedAt) < 10 {
                self.errorMessage = "iOS removed the Lock Screen activity right after it started. Check Live Activities for Hirte in iOS Settings."
            }
            self.stop()
        }
    }

    func window(_ id: UUID, phase: ScenePhase) {
        prepare()
        if phase == .active {
            activeWindows.insert(id)
            // Back from iOS Settings: don't depend on the update stream's timing.
            availabilityChanged(driver.isAvailable)
        } else {
            activeWindows.remove(id)
        }
        if activeWindows.isEmpty { markLastKnown() }
    }

    func removeWindow(_ id: UUID) {
        activeWindows.remove(id)
        if activeWindows.isEmpty { markLastKnown() }
    }

    func follows(hostID: UUID, address: String) -> Bool {
        selection?.hostID == hostID && selection?.address == address
    }

    /// Why this terminal can't be followed now, in words for the person; nil when it can.
    func followBlock(session: HostSession, terminal: Terminal?) -> String? {
        guard enabled else { return "Turn on Follow on Lock Screen in Live Activity Settings." }
        guard isAvailable else { return "Allow Live Activities for Hirte in iOS Settings." }
        guard session.state == .connected else { return "Connect to this machine to follow." }
        guard let terminal else { return "This terminal is gone." }
        return FollowTask.ineligibility(terminal)
    }

    func start(session: HostSession, terminal: Terminal) {
        prepare()
        availabilityChanged(driver.isAvailable)
        // Offered when it was possible, but things may have changed by the tap.
        if let block = followBlock(session: session, terminal: terminal) {
            errorMessage = block
            return
        }
        guard !activeWindows.isEmpty else {
            errorMessage = "Hirte has to be on screen to start following. Open it and try again."
            return
        }
        let task = FollowTask(hostID: session.host.id, terminal: terminal, now: .now)
        guard case .update(let state) = task.reduce(
            hostID: session.host.id, terminal: terminal, showTitle: showTitle, now: .now) else { return }
        stop()
        selection = task
        source = session
        observedTurn = terminal.turn
        needsReconciliation = false
        lastState = state
        errorMessage = nil
        routes = routes.filter { Date.now.timeIntervalSince($0.value.startedAt) < 8.5 * 60 * 60 }
        routes[task.followID] = task
        enqueue {
            guard self.selection?.followID == task.followID else { return }
            guard self.enabled, !self.activeWindows.isEmpty else {
                self.selection = nil
                self.lastState = nil
                self.source = nil
                // A menu runs its action after closing, so leaving right after the tap ends up here.
                if self.enabled { self.errorMessage = "Hirte left the screen before the activity could start. Follow it again." }
                return
            }
            await self.driver.removeAll()
            do {
                try self.driver.start(id: task.followID, state: state)
                self.driver.observeDismissal(self.dismissed(task))
                self.unconfirmedStart = task.followID
            } catch {
                self.selection = nil
                self.lastState = nil
                self.source = nil
                self.errorMessage = followStartFailure(error)
            }
        }
    }

    func dismissError() { errorMessage = nil }

    func startConfirmed() { unconfirmedStart = nil }

    private func availabilityChanged(_ available: Bool) {
        isAvailable = available
        // Turned off in iOS Settings: iOS ends the activity, so don't keep offering to stop it.
        if !available, selection != nil || completed != nil { stop() }
    }

    func stop() {
        unconfirmedStart = nil
        completed = nil
        completedPhase = nil
        selection = nil
        lastState = nil
        source = nil
        // Also removes completed activities, e.g. when opting out or replacing the follow.
        enqueue { await self.driver.removeAll() }
    }

    func hostsChanged(_ ids: Set<UUID>) {
        routes = routes.filter { ids.contains($0.value.hostID) }
        if let task = selection ?? completed, !ids.contains(task.hostID) { stop() }
    }

    func sessionRemoved(_ session: HostSession) {
        if source === session { stop() }
    }

    func disconnected(_ session: HostSession) {
        if source === session { markLastKnown() }
    }

    func received(_ session: HostSession, message: EventMessage? = nil) {
        // A restored follow has no session yet: its machine's, once connected, takes it up.
        if source == nil, selection?.hostID == session.host.id { source = session }
        guard source === session else { return }
        if let completed {
            if case .event(let event) = message, event.terminal == completed.address {
                switch event.change {
                case .restarted, .removed: stop(); return
                default: break
                }
            }
            guard let terminal = session.terminal(completed.address),
                  completed.matches(hostID: session.host.id, terminal: terminal) else { stop(); return }
            let isRead: Bool
            if let turn = terminal.turn, let seen = terminal.seenTurn { isRead = seen >= turn } else { isRead = false }
            if case .event(let event) = message, event.terminal == completed.address,
               case .labels = event.change, isRead {
                stop()
                return
            }
            let errorRead = completedPhase == .error && terminal.turn != completed.startTurn && isRead
            let doneRead = completedPhase == .done && terminal.agentState == .idle
            let newTask = completedPhase != .ended && terminal.agentState == .working
            if doneRead || newTask || errorRead { stop() }
            return
        }
        guard let task = selection else { return }
        guard !activeWindows.isEmpty, session.state == .connected else { markLastKnown(); return }
        let terminal = session.terminal(task.address)
        if needsReconciliation, let terminal, !FollowTask.canResume(terminal, observedTurn: observedTurn) {
            stop()
            return
        }
        needsReconciliation = false
        observedTurn = terminal?.turn
        if case .event(let event) = message, event.terminal == task.address {
            if FollowTask.awaitsTurn(after: event.change, previous: lastState?.phase, terminal: session.terminal(task.address)) {
                return
            }
            switch event.change {
            case .restarted, .removed:
                stop()
                return
            case .lost:
                finish(lastState.map {
                    var state = $0
                    state.phase = .ended
                    state.progress = nil
                    state.asOf = .now
                    return state
                }, seconds: 900)
                return
            default: break
            }
        }
        switch task.reduce(hostID: session.host.id, terminal: session.terminal(task.address), showTitle: showTitle, now: .now) {
        case .update(let state):
            lastState = state
            enqueue {
                guard self.selection?.followID == task.followID else { return }
                await self.driver.update(state)
            }
        case .end(let state, let seconds): finish(state, seconds: seconds)
        }
    }

    private func finish(_ state: AgentActivityAttributes.ContentState?, seconds: TimeInterval) {
        completed = seconds > 0 ? selection : nil
        completedPhase = state?.phase
        selection = nil
        lastState = nil
        if seconds <= 0 { source = nil }
        enqueue { await self.driver.end(state, seconds: seconds) }
    }

    private func markLastKnown() {
        guard var state = lastState, !state.isLastKnown, let id = selection?.followID else { return }
        state.isLastKnown = true
        needsReconciliation = true
        lastState = state
        // Keep a little time for ActivityKit to accept the final snapshot before iOS suspends us.
        var background = UIBackgroundTaskIdentifier.invalid
        let endBackground = {
            guard background != .invalid else { return }
            let task = background
            background = .invalid
            self.endBackgroundTask(task)
        }
        background = beginBackgroundTask(endBackground)
        enqueue {
            defer { endBackground() }
            if self.selection?.followID == id { await self.driver.update(state) }
        }
    }

    func route(for url: URL) -> FollowTask? {
        guard let id = AgentActivityAttributes.followID(from: url), let task = routes[id],
              Date.now.timeIntervalSince(task.startedAt) < 8.5 * 60 * 60 else { return nil }
        return task
    }

    /// Serialized platform calls keep stop/replacement/background updates in their original order.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task {
            await previous?.value
            await work()
        }
    }

    func waitForUpdates() async { await operation?.value }
}
