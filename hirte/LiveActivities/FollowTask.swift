import Foundation
import HerdrKit

struct FollowTask: Equatable, Codable {
    let followID: UUID
    let hostID: UUID
    let address: String
    let createdMs: UInt64
    let startTurn: UInt64?
    let startedAt: Date

    init(hostID: UUID, terminal: Terminal, now: Date) {
        followID = UUID()
        self.hostID = hostID
        address = terminal.address
        createdMs = terminal.createdMs
        startTurn = terminal.turn
        startedAt = now
    }

    func matches(hostID: UUID, terminal: Terminal) -> Bool {
        self.hostID == hostID && address == terminal.address && createdMs == terminal.createdMs
            && (startTurn == nil || terminal.turn.map { $0 >= startTurn! } == true)
    }

    static func canFollow(_ terminal: Terminal) -> Bool { ineligibility(terminal) == nil }

    /// Why this terminal can't be followed, in words for the person; nil when it can.
    static func ineligibility(_ terminal: Terminal) -> String? {
        guard terminal.isLive else { return "This terminal has ended." }
        // A `lost` event keeps the record live but sets its end reason/code.
        // Match reduce() here so Follow is never offered only to return silently.
        guard terminal.reason == nil, terminal.exitCode == nil else {
            return "This terminal session is no longer available."
        }
        // Part of the task's identity: without it a replaced terminal would look like the same one.
        guard terminal.createdMs > 0 else { return "This terminal has no stable session identity yet. Reconnect to the machine." }
        switch terminal.agentState {
        case .working, .needsYou: return nil
        case nil: return "No agent reports a status in this terminal."
        case .done, .idle, .error: return "Only a working or waiting agent can be followed."
        }
    }

    /// A changed turn during a connection gap may belong to another task. Without the
    /// intervening events (or an old core's missing counter), never follow that task automatically.
    static func canResume(_ terminal: Terminal, observedTurn: UInt64?) -> Bool {
        guard terminal.agentState == .working || terminal.agentState == .needsYou else { return true }
        guard let observedTurn else { return false }
        return terminal.turn == observedTurn
    }

    /// Core emits status before the turn increment. Keep the preceding working state until
    /// that next event, so an old seen label cannot hide the new unread completion.
    static func awaitsTurn(
        after change: TerminalEvent.Change, previous: AgentActivityAttributes.ContentState.Phase?, terminal: Terminal?
    ) -> Bool {
        guard previous == .working, terminal?.turn != nil, case .status(let status) = change else { return false }
        return status?.state == "done" || status?.state == "idle"
    }

    enum Reduction: Equatable {
        case update(AgentActivityAttributes.ContentState)
        /// Nil removes immediately; a final state stays visible for a bounded time.
        case end(AgentActivityAttributes.ContentState?, seconds: TimeInterval)
    }

    func reduce(hostID: UUID, terminal: Terminal?, showTitle: Bool, now: Date) -> Reduction {
        guard now.timeIntervalSince(startedAt) < 8 * 60 * 60,
              let terminal, matches(hostID: hostID, terminal: terminal) else {
            return .end(nil, seconds: 0)
        }
        guard terminal.isLive, terminal.reason == nil, terminal.exitCode == nil else {
            return .end(content(terminal, phase: .ended, showTitle: showTitle, now: now), seconds: 900)
        }
        switch terminal.agentState {
        case .working:
            return .update(content(terminal, phase: .working, showTitle: showTitle, now: now))
        case .needsYou:
            return .update(content(terminal, phase: .needsYou, showTitle: showTitle, now: now))
        case .done:
            return .end(content(terminal, phase: .done, showTitle: showTitle, now: now), seconds: 900)
        case .error:
            return .end(content(terminal, phase: .error, showTitle: showTitle, now: now), seconds: 1800)
        case .idle, nil:
            return .end(nil, seconds: 0)
        }
    }

    private func content(
        _ terminal: Terminal, phase: AgentActivityAttributes.ContentState.Phase, showTitle: Bool, now: Date
    ) -> AgentActivityAttributes.ContentState {
        let reported = terminal.statusMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? startedAt
        return .init(
            phase: phase,
            progress: phase == .working ? terminal.status?.progress.map { min(100, max(0, $0)) } : nil,
            since: min(now, reported), asOf: now, isLastKnown: false,
            headline: showTitle ? terminal.status?.title.map { String($0.prefix(80)) } : nil)
    }
}
