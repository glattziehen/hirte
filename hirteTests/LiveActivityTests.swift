import ActivityKit
import Foundation
@testable import HerdrKit
import SwiftUI
import Testing
import UIKit
@testable import hirte

@MainActor
struct FollowTaskTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let hostID = UUID()

    private func terminal(
        state: String = "working", turn: UInt64? = 4, seen: UInt64? = 3,
        created: UInt64 = 123, progress: Int? = 50, live: Bool = true
    ) throws -> Terminal {
        var json: [String: Any] = [
            "address": "remote/t7", "created_ms": created, "state": live ? "live" : "finished",
            "cwd": "/private/customer", "title": "private terminal", "status_ms": 9_000_000,
            "status": ["state": state, "title": "Private task", "msg": "secret", "kind": "auth",
                       "progress": progress ?? 0],
            "labels": seen.map { ["herdr.seen": String($0)] } ?? [:]
        ]
        if let turn { json["turn"] = turn }
        if progress == nil {
            var status = json["status"] as! [String: Any]
            status.removeValue(forKey: "progress")
            json["status"] = status
        }
        return try JSONDecoder().decode(Terminal.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func explicitEligibilityAndIdentity() throws {
        let original = try terminal()
        let task = FollowTask(hostID: hostID, terminal: original, now: now)
        #expect(FollowTask.canFollow(original))
        #expect(FollowTask.canFollow(try terminal(state: "blocked")))
        #expect(!FollowTask.canFollow(try terminal(state: "done")))
        #expect(!FollowTask.canFollow(try terminal(created: 0)))
        #expect(!task.matches(hostID: UUID(), terminal: original))
        #expect(!task.matches(hostID: hostID, terminal: try terminal(created: 124)))
        #expect(!task.matches(hostID: hostID, terminal: try terminal(turn: 2)))
        #expect(task.matches(hostID: hostID, terminal: try terminal(state: "blocked", turn: 5)))
        #expect(FollowTask.canResume(original, observedTurn: 4))
        #expect(!FollowTask.canResume(try terminal(turn: 5), observedTurn: 4))
        #expect(!FollowTask.canResume(try terminal(turn: nil), observedTurn: nil))
        #expect(FollowTask.canResume(try terminal(state: "done", turn: 5), observedTurn: 4))
    }

    @Test func ineligibilitySaysWhyForEachKindOfTerminal() throws {
        #expect(FollowTask.ineligibility(try terminal()) == nil)
        #expect(FollowTask.ineligibility(try terminal(state: "blocked")) == nil)
        let notNow = "Only a working or waiting agent can be followed."
        #expect(FollowTask.ineligibility(try terminal(state: "done")) == notNow)
        #expect(FollowTask.ineligibility(try terminal(state: "idle")) == notNow)
        #expect(FollowTask.ineligibility(try terminal(state: "error")) == notNow)
        #expect(FollowTask.ineligibility(try terminal(live: false)) == "This terminal has ended.")
        // Even with an agent visibly working: the honest reason is its missing identity.
        #expect(FollowTask.ineligibility(try terminal(created: 0)) == "This terminal has no stable session identity yet. Reconnect to the machine.")
        let shell = try JSONDecoder().decode(Terminal.self, from: Data(
            #"{"address":"t1","created_ms":123,"state":"live"}"#.utf8))
        #expect(FollowTask.ineligibility(shell) == "No agent reports a status in this terminal.")
    }

    @Test func startFailuresNameTheirCause() {
        let denied = followStartFailure(ActivityAuthorizationError.denied)
        #expect(denied.contains("iOS Settings") && !denied.contains("ActivityKit"))
        let limit = followStartFailure(ActivityAuthorizationError.globalMaximumExceeded)
        #expect(limit.contains("Too many") && !limit.contains("Settings") && !limit.contains("ActivityKit"))
        #expect(followStartFailure(ActivityAuthorizationError.targetMaximumExceeded) == limit)
        #expect(followStartFailure(ActivityAuthorizationError.visibility).contains("on screen"))
        #expect(followStartFailure(ActivityAuthorizationError.unsupported).contains("can't show"))
        #expect(followStartFailure(ActivityAuthorizationError.unentitled).contains("isn't allowed"))
        // Unexpected: only here does the text carry the code, for a report from a device.
        #expect(followStartFailure(ActivityAuthorizationError.persistenceFailure).contains("ActivityKit: persistenceFailure"))
        #expect(followStartFailure(NSError(domain: "Test", code: 1)).contains("could not start"))
    }

    @Test func lostSessionCannotOfferANewFollow() throws {
        var lost = try terminal()
        // EventState's `lost` update retains state == live and the last agent status.
        lost.reason = "lost"
        #expect(lost.isLive)
        #expect(!FollowTask.canFollow(lost))
        #expect(FollowTask.ineligibility(lost) == "This terminal session is no longer available.")
        lost.reason = nil
        lost.exitCode = 0
        #expect(!FollowTask.canFollow(lost))
        #expect(FollowTask.ineligibility(lost) == "This terminal session is no longer available.")
    }

    @Test func phasesRespectReadStateAndBlockedTurn() throws {
        let task = FollowTask(hostID: hostID, terminal: try terminal(), now: now)
        func reduce(_ terminal: Terminal?) -> FollowTask.Reduction {
            task.reduce(hostID: hostID, terminal: terminal, showTitle: false, now: now)
        }
        guard case .update(let blocked) = reduce(try terminal(state: "blocked", turn: 5, seen: 5)) else {
            Issue.record("Blocked must keep following even after a turn increment and read label")
            return
        }
        #expect(blocked.phase == .needsYou)
        guard case .end(let done?, let duration) = reduce(try terminal(state: "done", turn: 6, seen: 5)) else {
            Issue.record("Unread completion must end")
            return
        }
        #expect(done.phase == .done)
        #expect(duration == 900)
        #expect(reduce(try terminal(state: "done", turn: 6, seen: 6)) == .end(nil, seconds: 0))
        #expect(reduce(try terminal(state: "idle", turn: 6, seen: 6)) == .end(nil, seconds: 0))
        guard case .end(let error?, let errorDuration) = reduce(try terminal(state: "error")) else {
            Issue.record("Error must end")
            return
        }
        #expect(error.phase == .error)
        #expect(errorDuration == 1800)
        #expect(reduce(nil) == .end(nil, seconds: 0))
        guard case .end(let ended?, let endedDuration) = reduce(try terminal(live: false)) else {
            Issue.record("Finished terminal must end")
            return
        }
        #expect(ended.phase == .ended)
        #expect(endedDuration == 900)
        let lost = try JSONDecoder().decode(Terminal.self, from: Data(
            #"{"address":"remote/t7","created_ms":123,"state":"live","turn":4,"reason":"lost","status":{"state":"working"}}"#.utf8))
        guard case .end(let lostState?, _) = reduce(lost) else { Issue.record("Lost kept terminal must end"); return }
        #expect(lostState.phase == .ended)
    }

    @Test func payloadIsPrivateAndProgressIsBounded() throws {
        let original = try terminal(progress: 150)
        let task = FollowTask(hostID: hostID, terminal: original, now: now)
        guard case .update(let state) = task.reduce(
            hostID: hostID, terminal: original, showTitle: false, now: now) else { return }
        #expect(state.progress == 100)
        #expect(state.headline == nil)
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        for secret in ["private", "Private", "secret", "auth", "remote", "t7", hostID.uuidString] {
            #expect(!encoded.contains(secret))
        }
        #expect(Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]).keys)
                == Set(["phase", "progress", "since", "asOf", "isLastKnown"]))
        guard case .update(let optedIn) = task.reduce(
            hostID: hostID, terminal: original, showTitle: true, now: now) else { return }
        #expect(optedIn.headline == "Private task")
        let attributes = AgentActivityAttributes(followID: task.followID)
        #expect(AgentActivityAttributes.followID(from: attributes.url) == task.followID)
        #expect(!attributes.url.absoluteString.contains("remote"))
        #expect(AgentActivityAttributes.followID(from: URL(string: "hirte://follow/\(task.followID)/extra")!) == nil)
        #expect(AgentActivityAttributes.followID(from: URL(string: "hirte://follow/\(task.followID)?command=kill")!) == nil)
        #expect(AgentActivityAttributes.followID(from: URL(string: "https://follow/\(task.followID)")!) == nil)
    }

    @Test func statusBeforeTurnCannotHideAnUnreadCompletion() throws {
        let done = try terminal(state: "done", turn: 4, seen: 4)
        #expect(done.agentState == .idle)
        #expect(FollowTask.awaitsTurn(after: .status(done.status), previous: .working, terminal: done))
        #expect(!FollowTask.awaitsTurn(after: .turn(5), previous: .working, terminal: done))
        #expect(!FollowTask.awaitsTurn(after: .status(done.status), previous: .needsYou, terminal: done))
        #expect(!FollowTask.awaitsTurn(after: .status(done.status), previous: .working,
                                     terminal: try terminal(state: "done", turn: nil)))
        let task = FollowTask(hostID: hostID, terminal: try terminal(), now: now)
        guard case .end(let completed?, _) = task.reduce(
            hostID: hostID, terminal: try terminal(state: "done", turn: 5, seen: 4),
            showTitle: false, now: now) else { Issue.record("Next turn must finish visibly"); return }
        #expect(completed.phase == .done)
    }

    @Test func missingTurnAndExpiry() throws {
        let original = try terminal(turn: nil, seen: nil, progress: nil)
        let task = FollowTask(hostID: hostID, terminal: original, now: now)
        #expect(task.matches(hostID: hostID, terminal: original))
        guard case .update(let state) = task.reduce(
            hostID: hostID, terminal: original, showTitle: false, now: now) else { return }
        #expect(state.progress == nil)
        #expect(task.reduce(hostID: hostID, terminal: original, showTitle: false, now: now + 8 * 3600)
                == .end(nil, seconds: 0))
        guard case .end(let done?, _) = task.reduce(
            hostID: hostID, terminal: try terminal(state: "done", turn: nil, seen: nil),
            showTitle: false, now: now) else { Issue.record("Old cores must still finish"); return }
        #expect(done.phase == .done)
    }
}

@MainActor
private final class RecordingActivityDriver: LiveActivityDriver {
    var isAvailable = true
    var failure = false
    var currentID: UUID?
    var state: AgentActivityAttributes.ContentState?
    var starts = 0
    var maximumConcurrent = 0
    var removeCalls = 0
    var updates = 0
    var holdUpdates = false
    var pendingUpdate: CheckedContinuation<Void, Never>?
    var dismissed: (@MainActor () -> Void)?

    func restore(id: UUID) -> AgentActivityAttributes.ContentState? { currentID == id ? state : nil }
    func start(id: UUID, state: AgentActivityAttributes.ContentState) throws {
        if failure { throw NSError(domain: "Test", code: 1) }
        maximumConcurrent = max(maximumConcurrent, currentID == nil ? 1 : 2)
        currentID = id
        self.state = state
        starts += 1
    }
    func update(_ state: AgentActivityAttributes.ContentState) async {
        self.state = state
        updates += 1
        if holdUpdates { await withCheckedContinuation { pendingUpdate = $0 } }
    }
    func end(_ state: AgentActivityAttributes.ContentState?, seconds: TimeInterval) async {
        currentID = nil
        self.state = state
    }
    func removeAll() async {
        currentID = nil
        state = nil
        dismissed = nil
        removeCalls += 1
    }
    func observeDismissal(_ dismissed: @escaping @MainActor () -> Void) { self.dismissed = dismissed }
    var availabilityChanged: (@MainActor (Bool) -> Void)?
    func observeAvailability(_ changed: @escaping @MainActor (Bool) -> Void) { availabilityChanged = changed }
}

@MainActor
struct FollowControllerTests {
    /// A running follow, and what a later run of the app needs to take it over.
    private func followed() async throws -> (
        session: HostSession, terminal: Terminal, driver: RecordingActivityDriver, defaults: UserDefaults,
        task: FollowTask, controller: FollowController, window: UUID, reopen: () -> FollowController
    ) {
        let defaults = try #require(UserDefaults(suiteName: "LiveActivityTests.\(UUID())"))
        let driver = RecordingActivityDriver()
        let controller = FollowController(defaults: defaults, driver: driver)
        let session = HostSession(host: .makeDemo())
        session.start(keys: KeyLibrary())
        for _ in 0..<200 {
            if session.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let terminal = try #require(session.terminals.first(where: FollowTask.canFollow))
        controller.enabled = true
        let window = UUID()
        controller.window(window, phase: .active)
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        let task = try #require(controller.selection)
        let reopen = {
            let next = FollowController(defaults: defaults, driver: driver)
            next.window(UUID(), phase: .active)
            return next
        }
        return (session, terminal, driver, defaults, task, controller, window, reopen)
    }

    /// Edits what a previous run left, for what can't be produced by a demo session.
    private func editStored(_ defaults: UserDefaults, _ edit: (inout [String: Any], inout [String: Any]) -> Void) throws {
        let data = try #require(defaults.data(forKey: FollowController.followKey))
        var stored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var task = try #require(stored["task"] as? [String: Any])
        edit(&stored, &task)
        stored["task"] = task
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: FollowController.followKey)
    }

    @Test func sameTaskSurvivesReopeningAndItsTerminal() async throws {
        let f = try await followed()
        defer { f.session.stop() }
        #expect(f.driver.starts == 1)
        let removals = f.driver.removeCalls

        // Backgrounded and back in the same run.
        f.controller.window(f.window, phase: .background)
        await f.controller.waitForUpdates()
        #expect(f.driver.state?.isLastKnown == true)
        f.controller.window(f.window, phase: .active)
        f.controller.received(f.session)
        await f.controller.waitForUpdates()
        #expect(f.controller.selection == f.task)
        #expect(f.driver.state?.isLastKnown == false)

        // A new run of the app takes the same activity over: nothing to choose again.
        let reopened = f.reopen()
        await reopened.waitForUpdates()
        #expect(reopened.selection == f.task)
        #expect(reopened.follows(hostID: f.session.host.id, address: f.terminal.address))
        #expect(reopened.route(for: AgentActivityAttributes(followID: f.task.followID).url) == f.task)
        #expect(f.driver.starts == 1)
        #expect(f.driver.removeCalls == removals)
        #expect(f.driver.currentID == f.task.followID)

        // It keeps updating through the session of that machine, and it still ends as usual.
        let updates = f.driver.updates
        reopened.received(f.session)
        await reopened.waitForUpdates()
        #expect(reopened.selection == f.task)
        #expect(f.driver.updates == updates + 1)
        f.driver.dismissed?()
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        #expect(f.defaults.data(forKey: FollowController.followKey) == nil)
    }

    @Test func rejectedLostSessionKeepsTheCurrentFollow() async throws {
        let f = try await followed()
        defer { f.controller.stop(); f.session.stop() }
        let removals = f.driver.removeCalls
        var lost = f.terminal
        lost.reason = "lost"
        f.controller.start(session: f.session, terminal: lost)
        await f.controller.waitForUpdates()
        #expect(f.controller.selection == f.task)
        #expect(f.controller.errorMessage == "This terminal session is no longer available.")
        #expect(f.driver.currentID == f.task.followID)
        #expect(f.driver.starts == 1)
        #expect(f.driver.removeCalls == removals)
    }

    @Test func aReopenedFollowNeverBroadensToAnotherTask() async throws {
        // A turn that moved in the gap may be a different task.
        var f = try await followed()
        try editStored(f.defaults) { stored, _ in stored["observedTurn"] = 999 }
        var reopened = f.reopen()
        #expect(reopened.selection == f.task)
        reopened.received(f.session)
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        #expect(f.driver.currentID == nil)
        f.session.stop()

        // So may a terminal at the same address with another start.
        f = try await followed()
        try editStored(f.defaults) { _, task in task["createdMs"] = 1 }
        reopened = f.reopen()
        reopened.received(f.session)
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        #expect(f.driver.currentID == nil)
        f.session.stop()

        // Past iOS's limit it can't be the running activity any more.
        f = try await followed()
        try editStored(f.defaults) { _, task in task["startedAt"] = Date.now.timeIntervalSinceReferenceDate - 9 * 3600 }
        reopened = f.reopen()
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        #expect(f.defaults.data(forKey: FollowController.followKey) == nil)
        f.session.stop()

        // Another machine's session doesn't take it up.
        f = try await followed()
        reopened = f.reopen()
        let other = HostSession(host: .makeDemo())
        reopened.received(other)
        await reopened.waitForUpdates()
        #expect(reopened.selection == f.task)
        f.session.stop()
    }

    @Test func nothingComesBackAfterItEnded() async throws {
        // Dismissed or ended by iOS while the app wasn't running.
        var f = try await followed()
        f.driver.currentID = nil
        var reopened = f.reopen()
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        #expect(f.driver.starts == 1)
        #expect(f.defaults.data(forKey: FollowController.followKey) == nil)
        f.session.stop()

        // Stop Following.
        f = try await followed()
        f.controller.stop()
        await f.controller.waitForUpdates()
        #expect(f.defaults.data(forKey: FollowController.followKey) == nil)
        reopened = f.reopen()
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        f.session.stop()

        // The opt-out, also when it was left on in storage for the follow.
        f = try await followed()
        f.controller.enabled = false
        await f.controller.waitForUpdates()
        #expect(f.defaults.data(forKey: FollowController.followKey) == nil)
        f.session.stop()

        // The task's end.
        f = try await followed()
        f.controller.received(f.session, message: .event(TerminalEvent(
            seq: 1, terminal: f.terminal.address, change: .lost(reason: "Lost", exitCode: nil))))
        await f.controller.waitForUpdates()
        #expect(f.controller.selection == nil)
        #expect(f.defaults.data(forKey: FollowController.followKey) == nil)
        reopened = f.reopen()
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        f.session.stop()

        // Live Activities turned off in iOS Settings while the app wasn't running.
        f = try await followed()
        f.driver.isAvailable = false
        reopened = f.reopen()
        await reopened.waitForUpdates()
        #expect(reopened.selection == nil)
        #expect(f.defaults.data(forKey: FollowController.followKey) == nil)
        f.session.stop()
    }

    @Test func everyBlockedStartSaysWhyAndKnownStateIsObserved() async throws {
        let suite = "LiveActivityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = RecordingActivityDriver()
        let controller = FollowController(defaults: defaults, driver: driver)
        let session = HostSession(host: .makeDemo())
        session.start(keys: KeyLibrary())
        defer { session.stop() }
        for _ in 0..<200 {
            if session.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let terminal = try #require(session.terminals.first(where: FollowTask.canFollow))
        let window = UUID()

        // No active window is its own reason, not a silent return: first the launch's initial
        // phase, then the transition that makes the same window able to start.
        controller.enabled = true
        controller.window(window, phase: .inactive)
        controller.start(session: session, terminal: terminal)
        #expect(controller.errorMessage?.contains("on screen") == true)
        #expect(driver.starts == 0)
        controller.dismissError()
        controller.window(window, phase: .active)

        controller.enabled = false
        #expect(controller.followBlock(session: session, terminal: terminal)?.contains("Live Activity Settings") == true)
        controller.start(session: session, terminal: terminal)
        #expect(controller.errorMessage?.contains("Live Activity Settings") == true)
        controller.dismissError()
        controller.enabled = true
        #expect(controller.followBlock(session: session, terminal: nil) == "This terminal is gone.")
        #expect(controller.followBlock(session: session, terminal: terminal) == nil)

        // The switch in iOS Settings: from the update stream, and on coming back to Hirte.
        driver.isAvailable = false
        driver.availabilityChanged?(false)
        #expect(!controller.isAvailable)
        #expect(controller.followBlock(session: session, terminal: terminal)?.contains("iOS Settings") == true)
        controller.start(session: session, terminal: terminal)
        #expect(controller.errorMessage?.contains("iOS Settings") == true)
        #expect(driver.starts == 0)
        controller.dismissError()
        driver.isAvailable = true
        controller.window(window, phase: .active)
        #expect(controller.isAvailable)

        // A success says so; turning the switch off while following ends the follow.
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        #expect(driver.starts == 1)
        #expect(controller.unconfirmedStart == controller.selection?.followID)
        controller.startConfirmed()
        #expect(controller.unconfirmedStart == nil)
        driver.isAvailable = false
        driver.availabilityChanged?(false)
        await controller.waitForUpdates()
        #expect(controller.selection == nil)
        #expect(driver.currentID == nil)
        driver.isAvailable = true
        driver.availabilityChanged?(true)

        // Left right after the tap, with the start still queued: nothing starts, and it says so.
        controller.start(session: session, terminal: terminal)
        controller.window(window, phase: .inactive)
        await controller.waitForUpdates()
        #expect(driver.starts == 1)
        #expect(controller.selection == nil)
        #expect(controller.errorMessage?.contains("left the screen") == true)
        controller.dismissError()
        controller.window(window, phase: .active)

        // Removed by iOS right after the request, while on screen: visible, and not when away.
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        driver.dismissed?()
        await controller.waitForUpdates()
        #expect(controller.selection == nil)
        #expect(controller.errorMessage?.contains("right after it started") == true)
        controller.dismissError()
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        controller.window(window, phase: .background)
        driver.dismissed?()
        await controller.waitForUpdates()
        #expect(controller.selection == nil)
        #expect(controller.errorMessage == nil)
    }

    @Test func lastKnownHandoffDeduplicatesAndEndsItsOwnBackgroundTask() async throws {
        let suite = "LiveActivityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = RecordingActivityDriver()
        var expirations: [@MainActor () -> Void] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        let controller = FollowController(
            defaults: defaults, driver: driver,
            beginBackgroundTask: { expiration in
                expirations.append(expiration)
                return UIBackgroundTaskIdentifier(rawValue: expirations.count)
            },
            endBackgroundTask: { ended.append($0) })
        let session = HostSession(host: .makeDemo())
        session.start(keys: KeyLibrary())
        defer { session.stop() }
        for _ in 0..<200 {
            if session.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let terminal = try #require(session.terminals.first(where: FollowTask.canFollow))
        let window = UUID()
        controller.enabled = true
        controller.window(window, phase: .active)
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()

        // Expire while the final snapshot is still queued behind an earlier platform update.
        driver.holdUpdates = true
        controller.received(session)
        for _ in 0..<200 {
            if driver.pendingUpdate != nil { break }
            await Task.yield()
        }
        let previousUpdate = try #require(driver.pendingUpdate)
        driver.pendingUpdate = nil
        controller.window(window, phase: .inactive)
        controller.window(window, phase: .background)
        controller.disconnected(session)
        #expect(expirations.count == 1)
        #expect(ended.isEmpty)
        let firstExpiration = try #require(expirations.first)
        firstExpiration()
        firstExpiration()
        #expect(ended.map(\.rawValue) == [1])
        driver.holdUpdates = false
        previousUpdate.resume()
        await controller.waitForUpdates()
        #expect(driver.updates == 2)
        #expect(driver.state?.isLastKnown == true)
        #expect(ended.map(\.rawValue) == [1])
        controller.disconnected(session)
        controller.removeWindow(window)
        await controller.waitForUpdates()
        #expect(expirations.count == 1) // Still stale after the first handoff completed.

        // A resumed live snapshot permits a new handoff; an old expiry cannot end its task.
        controller.window(window, phase: .active)
        controller.received(session)
        await controller.waitForUpdates()
        driver.holdUpdates = true
        controller.window(window, phase: .inactive)
        for _ in 0..<200 {
            if driver.pendingUpdate != nil { break }
            await Task.yield()
        }
        let finalUpdate = try #require(driver.pendingUpdate)
        driver.pendingUpdate = nil
        #expect(expirations.count == 2)
        firstExpiration()
        #expect(ended.map(\.rawValue) == [1])
        expirations[1]()
        #expect(ended.map(\.rawValue) == [1, 2])
        driver.holdUpdates = false
        finalUpdate.resume()
        await controller.waitForUpdates()
        #expect(ended.map(\.rawValue) == [1, 2])

        // Normal completion also relinquishes the task, even if expiry arrives afterwards.
        controller.window(window, phase: .active)
        controller.received(session)
        await controller.waitForUpdates()
        controller.window(window, phase: .background)
        await controller.waitForUpdates()
        #expect(expirations.count == 3)
        #expect(ended.map(\.rawValue) == [1, 2, 3])
        expirations[2]()
        #expect(ended.map(\.rawValue) == [1, 2, 3])
    }

    @Test func lifecycleReplacementPrivacyAndDismissal() async throws {
        let suite = "LiveActivityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = RecordingActivityDriver()
        let controller = FollowController(defaults: defaults, driver: driver)
        let session = HostSession(host: .makeDemo())
        session.start(keys: KeyLibrary())
        defer { session.stop() }
        for _ in 0..<200 {
            if session.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.state == .connected)
        let terminal = try #require(session.terminals.first(where: FollowTask.canFollow))
        let window = UUID()
        controller.window(window, phase: .active)
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        #expect(!controller.enabled)
        #expect(!controller.showTitle)
        #expect(driver.starts == 0)
        #expect(driver.removeCalls == 1) // Relaunch removes all orphan activities.

        controller.enabled = true
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        let firstID = try #require(controller.selection?.followID)
        #expect(driver.currentID == firstID)
        #expect(driver.state?.headline == nil)
        #expect(controller.route(for: AgentActivityAttributes(followID: firstID).url)?.address == terminal.address)
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        #expect(controller.selection?.followID != firstID)
        #expect(driver.starts == 2)
        #expect(driver.maximumConcurrent == 1)

        // One inactive window must not mark another active window's activity stale.
        let secondWindow = UUID()
        controller.window(secondWindow, phase: .active)
        controller.window(window, phase: .background)
        await controller.waitForUpdates()
        #expect(driver.state?.isLastKnown == false)
        controller.window(secondWindow, phase: .background)
        await controller.waitForUpdates()
        #expect(driver.state?.isLastKnown == true)
        let asOf = driver.state?.asOf
        controller.disconnected(session)
        await controller.waitForUpdates()
        #expect(driver.state?.asOf == asOf)
        controller.window(window, phase: .active)
        controller.received(session)
        await controller.waitForUpdates()
        #expect(driver.state?.isLastKnown == false)

        driver.dismissed?()
        await controller.waitForUpdates()
        #expect(controller.selection == nil)
        #expect(driver.currentID == nil)

        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        controller.showTitle = true
        await controller.waitForUpdates()
        #expect(controller.selection == nil)
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        controller.hostsChanged([])
        await controller.waitForUpdates()
        #expect(driver.currentID == nil)
        #expect(controller.route(for: AgentActivityAttributes(followID: firstID).url) == nil)

        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        controller.sessionRemoved(session)
        await controller.waitForUpdates()
        #expect(driver.currentID == nil)

        for change: TerminalEvent.Change in [.removed, .restarted(terminal), .lost(reason: "Lost", exitCode: nil)] {
            controller.start(session: session, terminal: terminal)
            await controller.waitForUpdates()
            controller.received(session, message: .event(TerminalEvent(seq: 1, terminal: terminal.address, change: change)))
            await controller.waitForUpdates()
            #expect(controller.selection == nil)
            #expect(driver.currentID == nil)
            controller.stop()
            await controller.waitForUpdates()
            #expect(driver.state == nil) // Also removes the final ended UI.
        }

        driver.isAvailable = false
        let count = driver.starts
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        #expect(driver.starts == count)
        driver.isAvailable = true
        driver.failure = true
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        #expect(controller.selection == nil)
        #expect(controller.errorMessage != nil)
        controller.dismissError()
        #expect(controller.errorMessage == nil)
        driver.failure = false
        controller.start(session: session, terminal: terminal)
        await controller.waitForUpdates()
        controller.enabled = false
        await controller.waitForUpdates()
        #expect(driver.currentID == nil)
    }
}


/// Explicit local simulator/device validation; routine unit runs never request an activity.
@MainActor
struct ActivityKitPrototypeTests {
    /// After Live Activities were refused for this app (`LiveActivityUITests.testLockScreenPermission`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIRTE_LIVE_SYSTEM_TEST"] == "denied"))
    func refusedActivityThrowsWhatThePersonIsTold() async throws {
        let driver = ActivityKitDriver()
        #expect(!driver.isAvailable)
        let state = AgentActivityAttributes.ContentState(
            phase: .working, progress: nil, since: .now, asOf: .now, isLastKnown: false, headline: nil)
        #expect(throws: ActivityAuthorizationError.denied) { try driver.start(id: UUID(), state: state) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIRTE_LIVE_SYSTEM_TEST"] == "1"))
    func actualActivityCanStartUpdateAndEnd() async throws {
        let driver = ActivityKitDriver()
        #expect(driver.isAvailable)
        await driver.removeAll()
        let id = UUID()
        var state = AgentActivityAttributes.ContentState(
            phase: .working, progress: 42, since: .now, asOf: .now, isLastKnown: false, headline: nil)
        try driver.start(id: id, state: state)
        let activity = try #require(Activity<AgentActivityAttributes>.activities.first)
        #expect(activity.attributes.followID == id)
        // A later run takes the running activity over, with its content.
        #expect(ActivityKitDriver().restore(id: id)?.phase == .working)
        #expect(ActivityKitDriver().restore(id: UUID()) == nil)
        #expect(Activity<AgentActivityAttributes>.activities.count == 1)
        #expect(activity.content.state.headline == nil)
        state.isLastKnown = true
        await driver.update(state)
        // ActivityKit publishes the accepted content back to its local object asynchronously.
        for _ in 0..<100 {
            if activity.content.state.isLastKnown { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(activity.content.state.isLastKnown)
        #expect(try #require(activity.content.staleDate) <= Date.now)
        await driver.end(state, seconds: 900)
        for _ in 0..<100 {
            if activity.activityState == .ended || activity.activityState == .dismissed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(activity.activityState == .ended || activity.activityState == .dismissed)
        // An ended activity still on the Lock Screen is not running: it doesn't come back.
        #expect(ActivityKitDriver().restore(id: id) == nil)
        await driver.removeAll()
        for _ in 0..<100 {
            if activity.activityState == .dismissed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(activity.activityState == .dismissed)
        #expect(ActivityKitDriver().restore(id: id) == nil)
    }
}
