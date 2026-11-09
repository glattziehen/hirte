import Foundation

/// Unlike AgentState, this includes agents whose status has not been reported or understood.
public enum AgentOverviewState: String, CaseIterable, Sendable {
    case needsYou, error, working, done, unknown, idle

    public init(terminal: Terminal, held: AgentState? = nil) {
        guard let word = terminal.status?.state,
              ["blocked", "error", "working", "done", "idle"].contains(word),
              let state = terminal.agentState else { self = .unknown; return }
        self = Self(rawValue: state.rawValue) ?? .unknown
        if self == .idle, held == .done { self = .done }
    }

    fileprivate var priority: Int { Self.allCases.firstIndex(of: self)! }
}

public struct AgentOverviewRow: Identifiable, Sendable {
    public let terminal: Terminal
    public let state: AgentOverviewState
    public let ancestors: [String]
    public let childCount: Int
    /// Root only: the member responsible for moving the whole family into this section.
    public let reason: Terminal?
    public var id: String { terminal.address }
    public var depth: Int { ancestors.count }
}

public struct AgentOverviewGroup: Identifiable, Sendable {
    public let state: AgentOverviewState
    public let rows: [AgentOverviewRow]
    public var id: AgentOverviewState { state }
}

public enum AgentOverview {
    /// Known agent executables also remain visible before their first status report.
    public static func isAgent(_ terminal: Terminal) -> Bool {
        guard terminal.isLive else { return false }
        if terminal.status != nil { return true }
        if let agent = TerminalContext(terminal: terminal).agent,
           !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let program = terminal.foreground?.name ?? terminal.argv.first ?? ""
        return ["codex", "claude", "claude-code", "grok", "gemini", "muse"].contains(
            URL(fileURLWithPath: program).lastPathComponent.lowercased())
    }

    public static func title(_ terminal: Terminal) -> String {
        let title = terminal.status?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? terminal.displayName : title
    }

    /// Families use the highest relevant state; timestamps belong to the members causing it.
    /// Missing parents become roots. Cycles are cut deterministically at their lowest address.
    public static func groups(
        _ terminals: [Terminal], mode: AgentOverviewMode, sort: AgentOverviewSort,
        held: [String: AgentState] = [:]
    ) -> [AgentOverviewGroup] {
        let all = Dictionary(terminals.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = all.values.filter(isAgent).sorted { addressBefore($0.address, $1.address) }
        let addresses = Set(agents.map(\.address))
        let states = Dictionary(uniqueKeysWithValues: agents.map {
            ($0.address, AgentOverviewState(terminal: $0, held: held[$0.address]))
        })
        var parents: [String: String] = [:]
        if mode == .nested {
            for agent in agents {
                var cursor = agent.parent
                var visited: Set<String> = [agent.address]
                while let address = cursor, visited.insert(address).inserted, let parent = all[address] {
                    if addresses.contains(address) { parents[agent.address] = address; break }
                    cursor = parent.parent
                }
            }
            for agent in agents {
                var path: [String] = []
                var cursor: String? = agent.address
                while let address = cursor {
                    if let start = path.firstIndex(of: address) {
                        let root = path[start...].sorted(by: addressBefore).first!
                        parents.removeValue(forKey: root)
                        break
                    }
                    path.append(address)
                    cursor = parents[address]
                }
            }
        }
        let children = Dictionary(grouping: agents.filter { parents[$0.address] != nil }) { parents[$0.address]! }
        func members(_ root: Terminal) -> [Terminal] {
            [root] + (children[root.address] ?? []).flatMap { members($0) }
        }
        func before(_ lhs: Terminal, _ rhs: Terminal) -> Bool {
            if sort == .title {
                let order = title(lhs).localizedStandardCompare(title(rhs))
                if order != .orderedSame { return order == .orderedAscending }
            } else if lhs.statusMs != rhs.statusMs {
                guard let left = lhs.statusMs else { return false }
                guard let right = rhs.statusMs else { return true }
                return sort == .longestWaiting ? left < right : left > right
            }
            return addressBefore(lhs.address, rhs.address)
        }
        struct Family {
            let root: Terminal
            let state: AgentOverviewState
            let reason: Terminal
        }
        let families = agents.filter { parents[$0.address] == nil }.map { root in
            let family = members(root)
            let state = family.compactMap { states[$0.address] }.min { $0.priority < $1.priority }!
            let reason = family.filter { states[$0.address] == state }.sorted(by: before).first!
            return Family(root: root, state: state, reason: reason)
        }.sorted {
            before(sort == .title ? $0.root : $0.reason, sort == .title ? $1.root : $1.reason)
        }
        var rows: [AgentOverviewState: [AgentOverviewRow]] = [:]
        func append(_ terminal: Terminal, ancestors: [String], family: Family) {
            let descendants = children[terminal.address] ?? []
            rows[family.state, default: []].append(AgentOverviewRow(
                terminal: terminal, state: states[terminal.address]!, ancestors: ancestors,
                childCount: descendants.count,
                reason: ancestors.isEmpty && family.reason.address != terminal.address ? family.reason : nil))
            for child in descendants.sorted(by: before) {
                append(child, ancestors: ancestors + [terminal.address], family: family)
            }
        }
        for family in families { append(family.root, ancestors: [], family: family) }
        return AgentOverviewState.allCases.compactMap { state in
            rows[state].map { AgentOverviewGroup(state: state, rows: $0) }
        }
    }

    private static func addressBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .literal]) == .orderedAscending
    }
}
