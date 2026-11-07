import Foundation
import Testing
@testable import HerdrKit

private func overviewTerminal(
    _ address: String, state: String? = "idle", parent: String? = nil,
    timestamp: UInt64? = 10, title: String? = nil, turn: UInt64? = nil,
    seen: UInt64? = nil, program: String = "agent"
) throws -> Terminal {
    var values: [String: Any] = [
        "address": address, "argv": [program], "cwd": "/workspace/sample", "state": "live",
        "labels": seen.map { [Terminal.seenLabel: String($0)] } ?? [:],
        "cols": 80, "rows": 24, "created_ms": 1,
    ]
    if let state {
        var status: [String: Any] = ["state": state, "app": "agent"]
        if let title { status["title"] = title }
        values["status"] = status
    }
    if let timestamp { values["status_ms"] = timestamp }
    if let parent { values["parent"] = parent }
    if let turn { values["turn"] = turn }
    return try JSONDecoder().decode(Terminal.self, from: JSONSerialization.data(withJSONObject: values))
}

@Test func overviewNestedBlockedDescendantMovesWholeFamily() throws {
    let root = try overviewTerminal("t1", state: "idle")
    let child = try overviewTerminal("t2", state: "working", parent: "t1")
    let grandchild = try overviewTerminal("t3", state: "blocked", parent: "t2")
    let groups = AgentOverview.groups([root, child, grandchild], mode: .nested, sort: .lastStateChange)
    #expect(groups.map(\.state) == [.needsYou])
    #expect(groups[0].rows.map(\.id) == ["t1", "t2", "t3"])
    #expect(groups[0].rows.map(\.depth) == [0, 1, 2])
    #expect(groups[0].rows[0].reason?.address == "t3")
    #expect(groups[0].rows.map(\.state) == [.idle, .working, .needsYou])
}

@Test func overviewIndividualKeepsOwnStatus() throws {
    let terminals = [try overviewTerminal("t1"), try overviewTerminal("t2", state: "blocked", parent: "t1")]
    let groups = AgentOverview.groups(terminals, mode: .individual, sort: .lastStateChange)
    #expect(groups.map(\.state) == [.needsYou, .idle])
    #expect(groups.flatMap(\.rows).allSatisfy { $0.depth == 0 })
}

@Test func overviewWorkingOutranksUnreadCompletion() throws {
    let terminals = [try overviewTerminal("t1", state: "done"), try overviewTerminal("t2", state: "working", parent: "t1")]
    #expect(AgentOverview.groups(terminals, mode: .nested, sort: .title).first?.state == .working)
}

@Test func overviewErrorOutranksWorking() throws {
    let terminals = [try overviewTerminal("t1", state: "working"), try overviewTerminal("t2", state: "error", parent: "t1")]
    #expect(AgentOverview.groups(terminals, mode: .nested, sort: .title).first?.state == .error)
}

@Test func overviewHeldReadStateRetainsDoneUntilSelectionChanges() throws {
    let read = try overviewTerminal("t1", state: "done", turn: 4, seen: 4)
    #expect(AgentOverview.groups([read], mode: .nested, sort: .title).first?.state == .idle)
    #expect(AgentOverview.groups([read], mode: .nested, sort: .title, held: ["t1": .done]).first?.state == .done)
    let working = try overviewTerminal("t1", state: "working", turn: 4, seen: 4)
    #expect(AgentOverview.groups([working], mode: .nested, sort: .title, held: ["t1": .done]).first?.state == .working)
}

@Test func overviewUnknownAndUnreportedAreNeverIdleOrWorking() throws {
    let root = try overviewTerminal("t1")
    let unknown = try overviewTerminal("t2", state: "future", parent: "t1", turn: 4, seen: 4)
    let unreported = try overviewTerminal("t3", state: nil, program: "/usr/bin/codex")
    let shell = try overviewTerminal("t4", state: nil, program: "zsh")
    let groups = AgentOverview.groups([root, unknown, unreported, shell], mode: .nested, sort: .title)
    #expect(groups.map(\.state) == [.unknown])
    #expect(Set(groups.flatMap(\.rows).map(\.id)) == ["t1", "t2", "t3"])
}

@Test func overviewCyclesOrphansAndNonAgentBridgesStayVisible() throws {
    let terminals = [
        try overviewTerminal("t1", parent: "t2"), try overviewTerminal("t2", parent: "t1"),
        try overviewTerminal("t3", parent: "missing"), try overviewTerminal("t4", parent: "t5"),
        try overviewTerminal("t5", state: nil, parent: "t3", program: "zsh"),
        try overviewTerminal("t6", parent: "t6"),
    ]
    let rows = AgentOverview.groups(terminals, mode: .nested, sort: .title).flatMap(\.rows)
    #expect(Set(rows.map(\.id)) == ["t1", "t2", "t3", "t4", "t6"])
    #expect(rows.count == 5)
    #expect(rows.first { $0.id == "t1" }?.depth == 0)
    #expect(rows.first { $0.id == "t4" }?.ancestors == ["t3"])
}

@Test func overviewSortingUsesStableNaturalAddressTiesAndMissingDatesLast() throws {
    let terminals = [try overviewTerminal("t10"), try overviewTerminal("t2"), try overviewTerminal("t1", timestamp: nil)]
    for mode in AgentOverviewMode.allCases {
        for sort in [AgentOverviewSort.lastStateChange, .longestWaiting] {
            let rows = AgentOverview.groups(terminals, mode: mode, sort: sort).flatMap(\.rows)
            let reverse = AgentOverview.groups(terminals.reversed(), mode: mode, sort: sort).flatMap(\.rows)
            #expect(rows.map(\.id) == ["t2", "t10", "t1"])
            #expect(rows.map(\.id) == reverse.map(\.id))
        }
    }
}

@Test func overviewSortsWaitingFamiliesByTheirRelevantMember() throws {
    let terminals = [
        try overviewTerminal("t1", timestamp: 100),
        try overviewTerminal("t2", state: "blocked", parent: "t1", timestamp: 5),
        try overviewTerminal("t3", state: "blocked", timestamp: 10),
    ]
    let waiting = AgentOverview.groups(terminals, mode: .nested, sort: .longestWaiting).flatMap(\.rows)
    #expect(waiting.map(\.id) == ["t1", "t2", "t3"])
    let latest = AgentOverview.groups(terminals, mode: .nested, sort: .lastStateChange).flatMap(\.rows)
    #expect(latest.map(\.id) == ["t3", "t1", "t2"])
}

@Test func overviewTitleSortIgnoresTimestamp() throws {
    let terminals = [try overviewTerminal("t1", timestamp: 1, title: "Zebra"), try overviewTerminal("t2", timestamp: 2, title: "Alpha")]
    #expect(AgentOverview.groups(terminals, mode: .individual, sort: .title).flatMap(\.rows).map(\.id) == ["t2", "t1"])
}

@Test func overviewPreferencesRoundTripResetAndFutureValues() {
    var preferences = AgentOverviewPreferences()
    preferences.mode = .nested
    preferences.sort = .longestWaiting
    preferences.fields = [.branch, .project, .directory, .agent, .account]
    #expect(AgentOverviewPreferences(rawValue: preferences.rawValue) == preferences)
    #expect(AgentOverviewPreferences(rawValue: "invalid") == AgentOverviewPreferences())
    let future = AgentOverviewPreferences(rawValue: #"{"mode":["future"],"sort":["future"],"fields":["branch","future"]}"#)
    #expect(future.mode == .individual)
    #expect(future.sort == .lastStateChange)
    #expect(future.fields == [.branch])
    #expect(AgentOverviewPreferences(rawValue: #"{"fields":[]}"#).fields.isEmpty)
    preferences = AgentOverviewPreferences()
    #expect(preferences.fields == AgentOverviewPreferences.defaultFields)
}

@Test func overviewPreferencesPersistAcrossReloads() throws {
    let suite = "AgentOverviewTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = AgentOverviewPreferences()
    preferences.mode = .nested
    preferences.fields = [.branch, .account]
    defaults.set(preferences.rawValue, forKey: AgentOverviewPreferences.storageKey)
    let reloadedDefaults = try #require(UserDefaults(suiteName: suite))
    let reloaded = AgentOverviewPreferences(rawValue: reloadedDefaults.string(forKey: AgentOverviewPreferences.storageKey) ?? "")
    #expect(reloaded == preferences)
}

@Test func overviewIncludesUnreportedProvidersFromHostContext() throws {
    var terminal = try overviewTerminal("t1", state: nil, program: "env")
    terminal.labels["context.agent"] = "custom-agent"
    terminal.labels["context.created_ms"] = String(terminal.createdMs)
    let groups = AgentOverview.groups([terminal], mode: .nested, sort: .title)
    #expect(groups.first?.state == .unknown)
    #expect(groups.first?.rows.first?.id == "t1")
}

@Test func overviewIgnoresAnEarlierTerminalGenerationsAgentLabel() throws {
    let json = #"{"address":"t1","argv":["zsh"],"cwd":"/tmp","state":"live","labels":{"context.agent":"codex","context.created_ms":"1"},"cols":80,"rows":24,"created_ms":2}"#
    let terminal = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    #expect(!AgentOverview.isAgent(terminal))
}
