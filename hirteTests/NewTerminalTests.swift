import Foundation
import HerdrKit
import Testing
@testable import hirte

@MainActor
struct NewTerminalTests {
    private func terminal(_ firstMessage: String?) throws -> Terminal {
        let extra = firstMessage.map { #","first_message":\#($0)"# } ?? ""
        return try JSONDecoder().decode(Terminal.self, from: Data(#"{"address":"t8","argv":["reviewer"]\#(extra)}"#.utf8))
    }

    private func request(
        _ kind: NewTerminalView.Kind, options: WorkerStartOptions, placement: NewTerminalView.Placement = .space("s1")
    ) -> RunRequest? {
        NewTerminalView.request(
            kind: kind, command: "ls", template: "worker", task: " Fix it ", options: options,
            folder: "", name: "", placement: placement, machine: nil, keep: false, homeFolder: "/Users/me")
    }

    @Test func agentStartSendsTheTypedOptionsAndKeepsHerdrLabels() throws {
        let options = WorkerStartOptions(runtime: "codex", model: "some-model", reasoning: "medium")
        let request = try #require(request(.agent, options: options))
        #expect(request.argv == ["worker", "Fix it"])
        #expect(request.cwd == "/Users/me")
        #expect(request.labels == [
            "worker.harness": "codex", "worker.model": "some-model", "worker.effort": "medium",
            Terminal.seenLabel: "0", HerdrAppLayout.spaceLabel: "s1",
        ])
    }

    @Test func blankOptionsAndOtherKindsSendNoWorkerLabels() throws {
        let blank = try #require(request(.agent, options: WorkerStartOptions(), placement: .hidden))
        #expect(blank.labels == [Terminal.seenLabel: "0"])
        let typed = WorkerStartOptions(runtime: "codex", model: "m", reasoning: "low")
        let command = try #require(request(.command, options: typed))
        #expect(command.line == "ls")
        #expect(command.argv == nil)
        #expect(command.labels?.keys.contains { $0.hasPrefix("worker.") } == false)
    }

    @Test func workerTemplatesBlockStartUntilAllThreeAreValid() {
        let worker = TemplateInfo(name: "w", description: "", command: "agent-herdr-worker verifier")
        let required = WorkerStartOptions.isRequired(by: worker)
        #expect(required)
        for options in [WorkerStartOptions(), WorkerStartOptions(runtime: "codex", model: "m"),
                        WorkerStartOptions(runtime: "codex", model: "a b", reasoning: "high")] {
            let problem = options.problem(required: required)
            #expect(problem != nil)
            #expect(!NewTerminalView.describe(problem!).isEmpty)
        }
        #expect(WorkerStartOptions(runtime: "codex", model: "m", reasoning: "high").problem(required: required) == nil)
    }

    /// A run whose reply the test controls.
    private final class PendingRun {
        var continuation: CheckedContinuation<Terminal, Error>?
        var calls = 0
        func run() async throws -> Terminal {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func outcomes() async throws {
        for (json, expectOpen) in [(#"{"sent":true,"started":false}"#, true), (nil, true), ("null", true),
                                   (#"{"sent":false,"reason":"not ready"}"#, false)] as [(String?, Bool)] {
            let launch = TerminalLaunch()
            let pending = PendingRun()
            var opened: [String] = []
            launch.start(run: pending.run) { opened.append($0) } failed: { _ in Issue.record("no failure") }
            await settle()
            guard case .starting = launch.phase else { Issue.record("starting"); continue }
            launch.start(run: pending.run) { _ in } failed: { _ in }  // a second Start does nothing
            pending.continuation?.resume(returning: try terminal(json))
            await settle()
            #expect(pending.calls == 1)
            #expect(opened == (expectOpen ? ["t8"] : []))
            #expect(launch.phase == (expectOpen ? .editing : .notSent(address: "t8", reason: "not ready")))
        }
    }

    @Test func failureKeepsTheFormForAnotherTry() async throws {
        let launch = TerminalLaunch()
        let pending = PendingRun()
        var message: String?
        launch.start(run: pending.run) { _ in Issue.record("not started") } failed: { message = $0 }
        await settle()
        pending.continuation?.resume(throwing: HerdrError.rpc(code: -32000, message: "no such template", kind: "not_found", hint: "hc templates"))
        await settle()
        #expect(message == "no such template\nhc templates")
        #expect(launch.phase == .editing)
    }

    @Test func stopWaitingDropsALateReplyWithoutOpeningOrRetrying() async throws {
        for late in [#"{"sent":true}"#, #"{"sent":false}"#] {
            let launch = TerminalLaunch()
            let pending = PendingRun()
            var callbacks = 0
            launch.start(run: pending.run) { _ in callbacks += 1 } failed: { _ in callbacks += 1 }
            await settle()
            launch.stopWaiting()
            #expect(launch.phase == .stoppedWaiting)
            launch.start(run: pending.run) { _ in callbacks += 1 } failed: { _ in callbacks += 1 }
            pending.continuation?.resume(returning: try terminal(late))
            await settle()
            #expect(callbacks == 0)
            #expect(pending.calls == 1)
            #expect(launch.phase == .stoppedWaiting)
        }
    }

    /// Stop Waiting drops the sheet's callbacks right away, even while the call never returns.
    @Test func stopWaitingReleasesTheCallbacksOfACallThatNeverReturns() async throws {
        final class Owner {}
        weak var released: Owner?
        let launch = TerminalLaunch()
        let pending = PendingRun()
        do {
            let owner = Owner()
            released = owner
            launch.start(run: pending.run) { _ in _ = owner } failed: { _ in _ = owner }
        }
        await settle()
        #expect(released != nil, "Held while waiting")
        launch.stopWaiting()
        await settle()
        #expect(released == nil, "Not retained by the suspended call")
        pending.continuation?.resume(returning: try terminal(nil))
        await settle()
        #expect(launch.phase == .stoppedWaiting)
    }
}
