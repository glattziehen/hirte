import Foundation
import Testing
@testable import HerdrKit

private func contextTerminal(directory: String = "/work/repo", created: UInt64 = 42,
                             labels: [String: String] = [:]) throws -> Terminal {
    let data = try JSONSerialization.data(withJSONObject: [
        "address": "t1", "cwd": directory, "created_ms": created,
        "status": ["state": "working", "app": "codex"], "labels": labels,
    ])
    return try JSONDecoder().decode(Terminal.self, from: data)
}

@Test func contextUsesHostFieldsForTheSameDirectoryAndGeneration() throws {
    let terminal = try contextTerminal(labels: [
        "context.created_ms": "42", "context.directory": "/work/repo",
        "context.branch": "feature/mobile", "context.account": "Work",
        "context.project": "Repo",
    ])
    let context = TerminalContext(terminal: terminal)
    #expect(context.branch == "feature/mobile")
    #expect(context.directory == "/work/repo")
    #expect(context.project == "Repo")
    #expect(context.agent == "codex")
    #expect(context.account == "Work")
}

@Test func contextDoesNotReuseAFormerTerminalsAccountOrBranch() throws {
    let terminal = try contextTerminal(created: 99, labels: [
        "context.created_ms": "42", "context.directory": "/work/repo",
        "context.branch": "old", "context.agent": "other", "context.account": "Other",
    ])
    let context = TerminalContext(terminal: terminal, project: "Live project")
    #expect(context.branch == nil)
    #expect(context.account == nil)
    #expect(context.agent == "codex")
    #expect(context.project == "Live project")
}

@Test func contextDiscardsBranchAfterWorkingDirectoryChanges() throws {
    let terminal = try contextTerminal(directory: "/work/elsewhere", labels: [
        "context.created_ms": "42", "context.directory": "/work/repo",
        "context.branch": "old",
    ])
    #expect(TerminalContext(terminal: terminal).branch == nil)
}

@Test func contextDoesNotGuessAnAccountFromTheAgentName() throws {
    let context = TerminalContext(terminal: try contextTerminal())
    #expect(context.account == nil)
    #expect(context.agent == "codex")
}

@Test func aSpaceWorksWhereItsFirstTerminalDoes() throws {
    func row(_ directory: String) throws -> TerminalSection.Row {
        .init(terminal: try contextTerminal(directory: directory), depth: 0, tab: nil)
    }
    func section(_ kind: TerminalSection.Kind, _ rows: [TerminalSection.Row], subtitle: String? = nil) -> TerminalSection {
        TerminalSection(kind: kind, title: "site", subtitle: subtitle, rows: rows)
    }
    let space = TerminalSection.Kind.space(id: "s")
    #expect(section(space, [try row("/a"), try row("/b"), try row("/b")]).workingFolder == "/a")
    #expect(section(space, [], subtitle: "/recorded").workingFolder == "/recorded")
    #expect(section(space, [], subtitle: "").workingFolder == nil)
    #expect(section(.other, [try row("/a")]).workingFolder == nil, "other sections have unrelated rows")
    #expect(section(.machine(name: "m"), [try row("/a")]).workingFolder == nil)
}
