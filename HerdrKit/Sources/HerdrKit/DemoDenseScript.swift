import Foundation

/// What the demo machine shows.
public enum DemoScene: Sendable {
    /// Three projects with agents, tests, a dev server and a shell: what people try the app with.
    case standard
    /// Many agents and families, with long branch names and a worktree, standing still: to check
    /// density and layout. Only behind a Debug launch argument (`-hirte.demo.dense YES`).
    case dense
}

/// The dense scene's content: generic, like the standard scene's. Its statuses don't change, so
/// that captures of it compare.
enum DemoDenseScript {
    private static let home = DemoScript.home
    private static let website = home + "/projects/website"
    private static let shopAPI = home + "/projects/shop-api"
    private static let infra = home + "/projects/infra"
    private static let docs = home + "/projects/docs"
    private static let worktree = home + "/worktrees/shop-api/invoice-reminders"
    private static let longBranch = "feature/customer-portal/invoices-and-payment-reminders-rework"

    private static func ago(_ minutes: UInt64) -> UInt64 { DemoScript.now - minutes * 60_000 }

    private struct Agent {
        let address: String
        var parent: String?
        let folder: String
        let provider: String
        let account: String
        let branch: String
        let state: String
        let title: String
        var message: String?
        var progress: Int?
        let minutes: UInt64
        var kind: String?
    }

    private static let agents: [Agent] = [
        // Three children, each with its own provider.
        Agent(address: "t1", folder: website, provider: "codex", account: "Personal", branch: "feature/checkout-rework",
              state: "working", title: "Rework the checkout flow", message: "Splitting the payment step",
              progress: 40, minutes: 9),
        Agent(address: "t2", parent: "t1", folder: website, provider: "claude-code", account: "Work",
              branch: "feature/checkout-rework", state: "working", title: "Update the payment tests",
              message: "31 of 48 passed", progress: 65, minutes: 4),
        Agent(address: "t3", parent: "t1", folder: website, provider: "gemini", account: "Personal",
              branch: "feature/checkout-rework", state: "done", title: "Review the cart module",
              message: "2 notes left", minutes: 7),
        Agent(address: "t4", parent: "t1", folder: website, provider: "grok", account: "Work",
              branch: "feature/checkout-rework", state: "idle", title: "Write the release notes",
              message: "Waiting for the tests", minutes: 22),
        // Two levels deep, and the deepest one waits for you.
        Agent(address: "t5", folder: infra, provider: "codex", account: "Work", branch: "chore/build-pipeline",
              state: "working", title: "Upgrade the build pipeline", message: "Moving to the new runners",
              progress: 25, minutes: 31),
        Agent(address: "t6", parent: "t5", folder: infra, provider: "claude-code", account: "Work",
              branch: "chore/build-pipeline", state: "working", title: "Migrate the CI runners",
              message: "4 of 12 jobs moved", progress: 33, minutes: 18),
        Agent(address: "t7", parent: "t6", folder: infra, provider: "grok", account: "Work",
              branch: "chore/pin-runner-images", state: "blocked", title: "Rebuild the runner images?",
              message: "make images", minutes: 3, kind: "permission"),
        // A worktree on a very long branch.
        Agent(address: "t8", folder: worktree, provider: "claude-code", account: "Work", branch: longBranch,
              state: "working", title: "Add invoice reminders", message: "Writing the reminder job",
              progress: 70, minutes: 12),
        Agent(address: "t9", parent: "t8", folder: worktree, provider: "gemini", account: "Personal", branch: longBranch,
              state: "done", title: "Check the reminder emails", message: "6 templates checked", minutes: 5),
        // On their own.
        Agent(address: "t10", folder: shopAPI, provider: "claude-code", account: "Work", branch: "feature/orders",
              state: "blocked", title: "Run the database migration?", message: "npm run migrate",
              minutes: 12, kind: "permission"),
        Agent(address: "t11", folder: website, provider: "grok", account: "Work", branch: "fix/login-flake",
              state: "error", title: "Fix the flaky login test", message: "Timed out after 3 retries", minutes: 16),
        Agent(address: "t12", folder: infra, provider: "codex", account: "Personal", branch: "main",
              state: "done", title: "Upgraded Postgres to 18", message: "All checks green", minutes: 47),
        Agent(address: "t13", folder: docs, provider: "gemini", account: "Work", branch: "feature/api-reference-v3",
              state: "working", title: "Update the API reference", message: "Page 14 of 40", progress: 35, minutes: 6),
        Agent(address: "t14", folder: docs, provider: "helper", account: "Personal", branch: "main",
              state: "done", title: "Translate the pricing page", message: "3 languages", minutes: 58),
        Agent(address: "t15", folder: shopAPI, provider: "codex", account: "Personal", branch: "main",
              state: "idle", title: "Summarize the open issues", message: "Nothing new", minutes: 190),
    ]

    static func terminals() -> [DemoTerminal] {
        let reported = agents.map { agent -> DemoTerminal in
            var labels = [
                "context.created_ms": String(ago(agent.minutes + 20)),
                "context.directory": agent.folder,
                "context.branch": agent.branch,
                "context.agent": agent.provider,
                "context.account": agent.account,
                // Read up to here: "done" reads as unread, "idle" as looked at.
                Terminal.seenLabel: agent.state == "done" ? "1" : "2",
            ]
            if agent.folder == worktree { labels["context.project"] = "shop-api" }
            return DemoTerminal(
                address: agent.address, argv: ["agent"], cwd: agent.folder, title: "agent",
                status: .init(state: agent.state, app: "agent", title: agent.title, msg: agent.message,
                              kind: agent.kind, progress: agent.progress),
                labels: labels,
                foreground: .init(pid: 31_000, name: "agent", argv: ["agent"], cwd: agent.folder),
                createdMs: ago(agent.minutes + 20), parent: agent.parent, turn: 2,
                statusMs: ago(agent.minutes))
        }
        return reported + [
            // Hasn't reported a status yet: known as an agent by its provider only.
            DemoTerminal(
                address: "t16", argv: ["agent"], cwd: docs, title: "agent",
                labels: [
                    "context.created_ms": String(ago(2)), "context.directory": docs,
                    "context.branch": "main", "context.agent": "codex", "context.account": "Work",
                ],
                foreground: .init(pid: 31_016, name: "agent", argv: ["agent"], cwd: docs),
                createdMs: ago(2)),
            DemoTerminal(
                address: "t17", name: "dev-server", argv: ["npm", "run", "dev"], cwd: website,
                foreground: .init(pid: 29_910, name: "node", argv: ["node", "vite"], cwd: website),
                createdMs: ago(95)),
            DemoTerminal(
                address: "t18", argv: ["zsh"], cwd: shopAPI,
                foreground: .init(pid: 30_100, name: "zsh", argv: ["zsh"], cwd: shopAPI),
                createdMs: ago(64)),
            DemoTerminal(
                address: "t19", name: "logs", argv: ["tail", "-f", "app.log"], cwd: home + "/logs",
                foreground: .init(pid: 30_200, name: "tail", argv: ["tail", "-f", "app.log"], cwd: home + "/logs"),
                createdMs: ago(240)),
            DemoTerminal(
                address: "t20", name: "nightly-backup", argv: ["./backup.sh"], cwd: infra, state: "finished",
                createdMs: ago(300), exitCode: 0, reason: "exited"),
        ]
    }

    static func roles() -> [String: DemoScript.Role] {
        var roles: [String: DemoScript.Role] = [
            "t16": .agent(DemoScript.newAgentPaint(task: "")),
            "t17": .stream(paint: DemoScript.devServerPaint, lines: DemoScript.devServerLines, interval: .seconds(4)),
            "t18": .shell(history: "", cwd: shopAPI),
            "t19": .shell(history: "", cwd: home + "/logs"),
        ]
        for agent in agents {
            roles[agent.address] = .agent(DemoScript.newAgentPaint(task: agent.title))
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["HIRTE_SCROLL_TRACE"] == "1" {
            let output = ProcessInfo.processInfo.environment["HIRTE_COAST_OUTPUT"] == "1"
            let history = (0..<(output ? 14000 : 1000)).map { "sample \($0) ready 漢 e\u{301}\r\n" }.joined()
            if output {
                roles["t1"] = .stream(paint: history,
                    lines: (0..<2000).map { batch in
                        (0..<8).map { "sample \(14000 + batch * 8 + $0) ready 漢 e\u{301}\r\n" }.joined()
                    }, interval: .milliseconds(50))
            } else {
                roles["t1"] = .shell(history: history, cwd: website)
            }
        }
        #endif
        return roles
    }

    static let layout = """
        {"spaces":[\
        {"id":"spdensewebsite","name":"website","folder":"\(website)","tabs":[\
        {"id":"tbdense1","name":"","root":{"children":[{"content":{"terminal":"t1"}},{"content":{"terminal":"t11"}},{"content":{"terminal":"t17"}}]}}]},\
        {"id":"spdenseshopapi","name":"shop-api","folder":"\(shopAPI)","tabs":[\
        {"id":"tbdense2","name":"orders","root":{"children":[{"content":{"terminal":"t10"}},{"content":{"terminal":"t8"}}]}},\
        {"id":"tbdense3","name":"git","root":{"children":[{"content":{"terminal":"t15"}},{"content":{"terminal":"t18"}}]}}]},\
        {"id":"spdenseinfra","name":"infra","folder":"\(infra)","tabs":[\
        {"id":"tbdense4","name":"","root":{"children":[{"content":{"terminal":"t5"}},{"content":{"terminal":"t12"}},{"content":{"terminal":"t19"}}]}}]},\
        {"id":"spdensedocs","name":"docs","folder":"\(docs)","tabs":[\
        {"id":"tbdense5","name":"","root":{"children":[{"content":{"terminal":"t13"}},{"content":{"terminal":"t14"}},{"content":{"terminal":"t16"}}]}}]}]}
        """
}
