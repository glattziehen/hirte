import Foundation
import HerdrKit
import SwiftUI
import Testing
@testable import hirte

private func terminal(_ fields: [String: Any]) throws -> Terminal {
    let base: [String: Any] = ["address": "t1", "cwd": "/home/me/projects/site", "created_ms": 42, "state": "live"]
    let data = try JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new })
    return try JSONDecoder().decode(Terminal.self, from: data)
}

private func labels(folder: String = "/home/me/projects/site", branch: String? = "feature/dark",
                    agent: String? = "codex", account: String? = "Work") -> [String: String] {
    var labels = ["context.created_ms": "42", "context.directory": folder]
    labels["context.branch"] = branch
    labels["context.agent"] = agent
    labels["context.account"] = account
    return labels
}

private func working(_ labels: [String: String], cwd: String = "/home/me/projects/site") throws -> Terminal {
    try terminal(["cwd": cwd, "name": "agent", "labels": labels,
                  "status": ["state": "working", "app": "agent", "title": "Add dark mode"]])
}

private let defaults = AgentOverviewPreferences.defaultFields

private func row(
    _ terminal: Terminal, project: String? = "site", space: String? = nil, fields: Set<AgentOverviewField> = defaults,
    parent: TerminalContext? = nil, message: String? = nil, showsProvider: Bool = true
) -> RowContext {
    .agent(terminal: terminal, state: AgentOverviewState(terminal: terminal),
           context: TerminalContext(terminal: terminal, project: project), fields: fields, space: space,
           parent: parent, message: message, showsProvider: showsProvider)
}

@MainActor
struct RowContextTests {
    private let separator = Terminal.detailSeparator

    @Test func theProjectLeadsAndItsFolderIsNotRepeated() throws {
        let context = row(try working(labels()))
        #expect(context.folder == nil)
        #expect(context.project == "site")
        #expect(context.elsewhere == nil, "the project's own folder needs no line")
        #expect(context.sentence == "site feature/dark\(separator)Work")
        #expect(context.label.contains("~/projects/site"), "VoiceOver still has it")
    }

    @Test func aSpaceThatIsTheProjectIsSaidOnce() throws {
        let same = row(try working(labels()), space: "site", fields: defaults.union([.space]))
        #expect(same.project == "site")
        let other = row(try working(labels()), space: "shop", fields: defaults.union([.space]))
        #expect(other.space == "shop")
        #expect(other.project == "site")
        #expect(other.folder == nil)
        #expect(other.sentence == "shop\(separator)site feature/dark\(separator)Work")
    }

    @Test func aSpaceBeforeAFolderKeepsThemApart() throws {
        let context = row(try working(labels()), project: nil, space: "shop",
                          fields: defaults.subtracting([.project]).union([.space]))
        #expect(context.project == "shop")
        #expect(context.folder == nil)
        #expect(context.elsewhere == "~/projects/site", "not attached to the space's name")
    }

    @Test func aProviderWithAnIconIsLeftToTheIconButStaysInTheLabel() throws {
        let shown = row(try working(labels()), showsProvider: true)
        #expect(!shown.who.contains("codex"))
        #expect(shown.label.contains("codex"))
        let unknown = row(try working(labels(agent: "helper")), showsProvider: false)
        #expect(unknown.who.contains("helper"), "no icon says who it is: the text does")
    }

    @Test func onlyBundledProvidersCountAsShownByTheirIcon() throws {
        #expect(AgentProviderIcon.hasAsset(try working(labels(agent: "codex"))))
        #expect(AgentProviderIcon.hasAsset(try working(labels(agent: "claude-code"))))
        #expect(!AgentProviderIcon.hasAsset(try working(labels(agent: "helper"))))
    }

    @Test func anAgentWithoutAReportedStateStaysUnknown() throws {
        let silent = try terminal(["argv": ["agent"], "labels": labels(agent: "codex")])
        let state = AgentOverviewState(terminal: silent)
        #expect(state == .unknown)
        #expect(state.statusWord == nil, "the open ring, no made-up color")
        #expect(state.title == "Unknown")
    }

    @Test func aChildLeavesOutWhatItsParentSaysAndKeepsWhoRunsIt() throws {
        let parent = TerminalContext(terminal: try working(labels()), project: "site")
        let child = row(try working(labels(agent: "gemini", account: "Personal")), parent: parent)
        #expect(child.project == nil)
        #expect(child.branch == nil)
        #expect(child.folder == nil)
        #expect(child.elsewhere == nil)
        #expect(child.who == ["Personal"])
        #expect(child.label == "gemini, Personal", "the identity reaches VoiceOver too")
    }

    @Test func aChildOnAnotherBranchSaysSo() throws {
        let parent = TerminalContext(terminal: try working(labels()), project: "site")
        let child = row(try working(labels(branch: "fix/other")), parent: parent)
        #expect(child.branch == "fix/other")
    }

    @Test func aWorktreeGetsItsOwnLineAndKeepsItsProject() throws {
        let folder = "/home/me/worktrees/shop-api/reminders"
        let context = row(try working(labels(folder: folder), cwd: folder), project: "shop-api")
        #expect(context.project == "shop-api")
        #expect(context.folder == nil)
        #expect(context.elsewhere == "~/worktrees/shop-api/reminders")
        #expect(context.label.contains("~/worktrees/shop-api/reminders"))
    }

    @Test func withTheProjectOffTheWholeFolderStandsInForIt() throws {
        let context = row(try working(labels()), fields: defaults.subtracting([.project]))
        #expect(context.folder == "~/projects/")
        #expect(context.project == "site")
        #expect(context.sentence == "~/projects/site feature/dark\(separator)Work", "not only its last part")
    }

    @Test func aFieldSwitchedOffIsGone() throws {
        let context = row(try working(labels()), fields: defaults.subtracting([.branch, .account, .directory]))
        #expect(context.branch == nil)
        #expect(context.who.isEmpty)
        #expect(!context.label.contains("feature/dark"))
        #expect(!context.label.contains("Work"))
        #expect(!context.label.contains("~/projects"))
    }

    @Test func missingValuesAreNotMadeUp() throws {
        let context = row(try working(labels(branch: nil, agent: nil, account: nil)))
        #expect(context.branch == nil)
        #expect(context.who.isEmpty)
        #expect(context.sentence == "site")
    }

    @Test func aBranchFromAnotherFolderIsNotBelieved() throws {
        // Provenance stays with TerminalContext: the label belongs to where it was written.
        let moved = try working(labels(folder: "/home/me/projects/other"))
        #expect(row(moved, project: nil).branch == nil)
    }

    @Test func theStatusStaysReadableWithEveryFieldOff() throws {
        let context = row(try working(labels()), project: nil, fields: [], showsProvider: false)
        #expect(context.who == ["Working"])
        #expect(context.label == "Working")
    }

    @Test func noSentenceEndsOnASeparator() throws {
        let contexts = [
            row(try working(labels(account: nil))),
            row(try working(labels(branch: nil))),
            row(try working(labels()), project: nil, fields: [.account]),
        ]
        for context in contexts {
            #expect(!context.sentence.hasSuffix(separator))
            #expect(!context.sentence.hasPrefix(separator))
        }
    }

    @Test func aShellSaysWhatItRuns() throws {
        let server = try terminal(["name": "dev-server",
                                   "foreground": ["pid": 1, "name": "node", "argv": ["node"], "cwd": "/home/me/projects/site"]])
        let context = RowContext.terminal(server, inSpace: true, sharedFolder: "/home/me/projects/site", parent: nil)
        #expect(context.who == ["node"])
        #expect(context.elsewhere == nil, "the header says the folder")
    }

    @Test func aTerminalElsewhereSaysWhere() throws {
        let shell = try terminal(["name": "zsh"])
        let context = RowContext.terminal(shell, inSpace: true, sharedFolder: "/home/me/other", parent: nil)
        #expect(context.elsewhere == "~/projects/site")
    }

    @Test func aChildsTextStepsInFromItsParents() {
        let parentText = SidebarMetrics.iconSize + SidebarMetrics.columnGap
        for depth in 1...SidebarMetrics.maxFamilyDepth {
            let text = FamilyRails.indent(depth) + SidebarMetrics.childIconSize + SidebarMetrics.childColumnGap
            #expect(text == parentText + CGFloat(depth) * SidebarMetrics.familyStep)
        }
    }

    @Test func aRailRunsUnderTheIconItStartsFrom() {
        #expect(FamilyRails.railX(1) == SidebarMetrics.iconSize / 2)
        #expect(FamilyRails.railX(2) == FamilyRails.indent(1) + SidebarMetrics.childIconSize / 2)
    }
}
