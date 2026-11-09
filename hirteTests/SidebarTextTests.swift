import Foundation
import HerdrKit
import SwiftUI
import Testing
@testable import hirte

private func terminal(_ fields: [String: Any]) throws -> Terminal {
    let base: [String: Any] = ["address": "t1", "cwd": "/home/me/projects/site", "created_ms": 42]
    let data = try JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new })
    return try JSONDecoder().decode(Terminal.self, from: data)
}

@MainActor
struct SidebarTextTests {
    private let separator = Terminal.detailSeparator

    @Test func anAgentsTaskIsItsTitleAndItsNameMovesToTheDetail() throws {
        let agent = try terminal([
            "state": "live", "name": "agent",
            "status": ["state": "working", "app": "agent", "title": "Add dark mode"],
            "labels": ["context.created_ms": "42", "context.directory": "/home/me/projects/site",
                       "context.branch": "feature/dark"],
        ])
        #expect(agent.headline(inSpace: true) == "Add dark mode")
        #expect(agent.detail(inSpace: true, sharedFolder: "/home/me/projects/site")
            == "feature/dark\(separator)agent")
    }

    @Test func aFolderIsOnlyRepeatedWhereItDiffersFromTheHeader() throws {
        let shell = try terminal(["state": "live", "name": "zsh"])
        #expect(shell.headline(inSpace: true) == "zsh")
        #expect(shell.detail(inSpace: true, sharedFolder: "/home/me/projects/site") == nil)
        #expect(shell.detail(inSpace: true, sharedFolder: "/home/me/other") == "~/projects/site")
        #expect(shell.detail(inSpace: true) == "~/projects/site")
    }

    @Test func aProgramOtherThanTheNameStaysVisible() throws {
        let server = try terminal(["state": "live", "name": "dev-server",
                                   "foreground": ["pid": 1, "name": "node", "argv": ["node"], "cwd": "/home/me/projects/site"]])
        #expect(server.detail(inSpace: true, sharedFolder: "/home/me/projects/site") == "node")
    }

    @Test func aFinishedTerminalSaysHowItEnded() throws {
        #expect(try terminal(["state": "finished", "name": "job", "exit_code": 3]).detail(inSpace: false) == "exited 3")
        #expect(try terminal(["state": "finished", "name": "job"]).detail(inSpace: false) == "finished")
    }

    @Test func aChildLeavesOutWhatItsParentSays() throws {
        let labels: [String: String] = ["context.created_ms": "42", "context.directory": "/home/me/projects/site",
                                        "context.branch": "feature/dark"]
        let parent = try terminal(["state": "live", "name": "agent", "labels": labels])
        let child = try terminal(["state": "live", "name": "tests", "labels": labels])
        #expect(child.detail(inSpace: true, sharedFolder: nil, parent: parent) == nil)
        #expect(child.detail(inSpace: true, sharedFolder: nil, parent: nil)
            == "feature/dark\(separator)~/projects/site")
    }

    @Test func railsFollowAFamily() {
        func rails(_ depths: [Int]) -> [FamilyRails] { FamilyRails.layout(depths: depths) }
        #expect(rails([0, 0]).allSatisfy { !$0.inFamily }, "unrelated rows aren't a family")
        #expect(rails([0, 1, 1]) == [
            FamilyRails(depth: 0, continuing: [], opensDown: true),
            FamilyRails(depth: 1, continuing: [1], opensDown: false),
            FamilyRails(depth: 1, continuing: [], opensDown: false),
        ])
        #expect(rails([0, 1, 2, 1, 0]) == [
            FamilyRails(depth: 0, continuing: [], opensDown: true),
            FamilyRails(depth: 1, continuing: [1], opensDown: true),
            FamilyRails(depth: 2, continuing: [1], opensDown: false),
            FamilyRails(depth: 1, continuing: [], opensDown: false),
            FamilyRails(depth: 0, continuing: [], opensDown: false),
        ])
        #expect(rails([0, 9]).last?.depth == SidebarMetrics.maxFamilyDepth, "deep families stay in the column")
    }

    @Test func onlyFamilyMembersHideTheLinesBetweenThem() {
        let rails = FamilyRails.layout(depths: [0, 0, 1, 1, 0])
        #expect(rails[0].hiddenSeparators == [], "a row on its own keeps them")
        #expect(rails[1].hiddenSeparators == .bottom, "the parent, to its child")
        #expect(rails[2].hiddenSeparators == [.top, .bottom])
        #expect(rails[3].hiddenSeparators == .top, "the last child keeps the line below the family")
    }

    @Test func needsYouCountsInEnglish() {
        #expect(NeedsYouBadge.text(1) == "1 needs you")
        #expect(NeedsYouBadge.text(2) == "2 need you")
    }
}
