import Foundation

public enum AgentOverviewMode: String, CaseIterable, Codable, Sendable {
    case individual, nested
}

public enum AgentOverviewSort: String, CaseIterable, Codable, Sendable {
    case lastStateChange, longestWaiting, title
}

public enum AgentOverviewField: String, CaseIterable, Codable, Sendable {
    case icon, space, name, message, time, progress, branch, project, directory, agent, account
}

/// One app-wide configuration. Strings from newer versions are ignored on decode.
public struct AgentOverviewPreferences: Equatable, Sendable {
    public static let storageKey = "agents.overview"
    public static let defaultFields: Set<AgentOverviewField> = [.icon, .time, .progress, .branch, .project, .directory, .agent, .account]
    public var mode: AgentOverviewMode = .individual
    public var sort: AgentOverviewSort = .lastStateChange
    public var fields: Set<AgentOverviewField> = Self.defaultFields

    public init() {}

    public init(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        mode = values["mode"]?.first.flatMap(AgentOverviewMode.init(rawValue:)) ?? .individual
        sort = values["sort"]?.first.flatMap(AgentOverviewSort.init(rawValue:)) ?? .lastStateChange
        if let saved = values["fields"] { fields = Set(saved.compactMap(AgentOverviewField.init(rawValue:))) }
    }

    public var rawValue: String {
        let values = ["mode": [mode.rawValue], "sort": [sort.rawValue], "fields": fields.map(\.rawValue).sorted()]
        guard let data = try? JSONEncoder().encode(values) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
