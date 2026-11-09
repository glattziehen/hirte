import Foundation
import Testing
@testable import HerdrKit

private func runReply(_ firstMessage: String?) -> String {
    let extra = firstMessage.map { #","first_message":\#($0)"# } ?? ""
    return #"{"address":"t9","argv":["reviewer","Check it"],"cwd":"/tmp","state":"live","labels":{},"cols":80,"rows":24,"created_ms":1\#(extra)}"#
}

/// Through the real client: what `terminal.run` says about the first message reaches the app.
@Test func runKeepsWhetherTheFirstMessageWentIn() async throws {
    let cases: [(json: String?, expected: FirstMessage?)] = [
        (#"{"sent":true,"started":true,"turn":3}"#, FirstMessage(sent: true, started: true, turn: 3)),
        (#"{"sent":true,"started":false}"#, FirstMessage(sent: true, started: false)),
        (#"{"sent":false,"reason":"agent not ready"}"#, FirstMessage(sent: false, reason: "agent not ready")),
        ("null", nil),
        (nil, nil),  // older cores don't send it
    ]
    for item in cases {
        let core = FakeCore()
        core.respond = { core, id, method in
            #expect(method == "terminal.run")
            core.reply(id, runReply(item.json))
        }
        let client = try await HerdrClient.connect(over: core)
        let terminal = try await client.run(RunRequest(argv: ["reviewer", "Check it"]))
        #expect(terminal.address == "t9")
        #expect(terminal.isLive)
        #expect(terminal.firstMessage == item.expected, "\(item.json ?? "absent")")
        await client.close()
    }
}

/// A first message without its required `sent` is not silently taken for success.
@Test func malformedFirstMessageIsAnError() async throws {
    let core = FakeCore()
    core.respond = { core, id, _ in core.reply(id, runReply(#"{"reason":"x"}"#)) }
    let client = try await HerdrClient.connect(over: core)
    await #expect(throws: HerdrError.self) { try await client.run(RunRequest(argv: ["reviewer"])) }
    await client.close()
}

/// A caller that stops waiting (task cancelled) doesn't end the call: the late reply still
/// arrives, once, and the connection closing ends any wait that never gets one.
@Test(.timeLimit(.minutes(1)))
func cancelledCallerStillGetsOneLateReplyAndCloseEndsTheRest() async throws {
    let core = FakeCore()
    let ids = Locked<[Int]>([])
    core.respond = { _, id, _ in ids.withLock { $0.append(id) } }
    let client = try await HerdrClient.connect(over: core)
    let waiting = Task { try await client.run(RunRequest(argv: ["reviewer"])) }
    while ids.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
    waiting.cancel()
    let id = ids.withLock { $0[0] }
    core.reply(id, runReply(#"{"sent":false,"reason":"late"}"#))
    core.reply(id, runReply(#"{"sent":true}"#))  // a duplicate is dropped
    let late = try await waiting.value
    #expect(late.firstMessage == FirstMessage(sent: false, reason: "late"))
    #expect(ids.withLock { $0.count } == 1, "Nothing was sent again")

    let never = Task { try await client.run(RunRequest(argv: ["reviewer"])) }
    while ids.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
    never.cancel()
    await client.close()
    await #expect(throws: HerdrError.self) { try await never.value }
}

@Test func workerStartOptionsAreAllOrNothingAndFollowTheAdapterRules() {
    let worker = TemplateInfo(name: "w", description: "", command: "$HOME/.local/bin/agent-herdr-worker implementer", error: nil)
    let plain = TemplateInfo(name: "p", description: "", command: "agent --role reviewer", error: nil)
    #expect(WorkerStartOptions.isRequired(by: worker))
    #expect(!WorkerStartOptions.isRequired(by: plain))

    let blank = WorkerStartOptions()
    #expect(blank.problem(required: false) == nil)
    #expect(blank.problem(required: true) == .incomplete)
    #expect(blank.labels.isEmpty)
    #expect(WorkerStartOptions(model: "m").problem(required: false) == .incomplete, "Partly filled is never sent")

    let good = WorkerStartOptions(runtime: " claude ", model: "claude-opus-5-5", reasoning: "high")
    #expect(good.problem(required: true) == nil)
    #expect(good.labels == ["worker.harness": "claude", "worker.model": "claude-opus-5-5", "worker.effort": "high"])
    #expect(WorkerStartOptions(runtime: "cla ude", model: "m", reasoning: "high").problem(required: true) == .invalidRuntime)
    #expect(WorkerStartOptions(runtime: "codex", model: "gpt/5", reasoning: "high").problem(required: true) == .invalidModel)
    #expect(WorkerStartOptions(runtime: "codex", model: "m", reasoning: "huge").problem(required: true) == .invalidReasoning)
}

@Test func demoTemplateRunsReportTheirFirstMessage() async throws {
    let client = try await HerdrClient.connectDemo()
    let agent = try await client.run(RunRequest(argv: ["reviewer", "Look"]))
    #expect(agent.firstMessage?.sent == true)
    let command = try await client.run(RunRequest(line: "ls"))
    #expect(command.firstMessage == nil)
    await client.close()
}

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
