import Foundation

/// What to start in a new terminal (`terminal.run`).
public struct RunRequest: Encodable, Sendable {
    /// Program and arguments, or a template name followed by its task. With neither
    /// `argv` nor `line`, the machine's own shell.
    public var argv: [String]?
    /// A shell line, run by the machine's shell (`sh -c`).
    public var line: String?
    public var cwd: String?
    public var name: String?
    public var labels: [String: String]?
    /// Replace a lost program with a fresh shell in place (never re-runs the command).
    public var keep: Bool?
    public var env: [String: String]?
    /// Another machine added on this core.
    public var on: String?

    /// The terminal identity herdr-app gives its terminals.
    public static let terminalEnvironment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"]

    public init(
        argv: [String]? = nil, line: String? = nil, cwd: String? = nil, name: String? = nil,
        labels: [String: String]? = nil, keep: Bool? = nil, env: [String: String]? = Self.terminalEnvironment,
        on: String? = nil
    ) {
        self.argv = argv
        self.line = line
        self.cwd = cwd
        self.name = name
        self.labels = labels
        self.keep = keep
        self.env = env
        self.on = on
    }
}

/// An agent role saved as `~/.config/herdr-core/templates/<name>.md` on the machine.
public struct TemplateInfo: Decodable, Hashable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let command: String
    /// Set when the file can't be used.
    public let error: String?
    public var id: String { name }

    public init(name: String, description: String, command: String, error: String? = nil) {
        self.name = name
        self.description = description
        self.command = command
        self.error = error
    }
}

/// Start values for worker-adapter templates. A compatibility convention, not herdr-core
/// protocol: a template whose command runs `agent-herdr-worker` refuses to start unless its
/// terminal carries the labels `worker.harness`, `worker.model` and `worker.effort`.
/// herdr-core 0.1.18's `templates.list` gives only a template's name, description and command,
/// so such a template is recognized by its command, and these values are what the person typed:
/// never guessed, remembered or copied from another terminal. The adapter on the machine checks
/// them again and stays authoritative (allowed runtimes, roles, models).
/// Revisit when `templates.list` describes a template's parameters: show those instead.
public struct WorkerStartOptions: Equatable, Sendable {
    public static let harnessLabel = "worker.harness"
    public static let modelLabel = "worker.model"
    public static let effortLabel = "worker.effort"
    /// The reasoning levels the adapter accepts.
    public static let efforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra", "inherit"]

    public enum Problem: Equatable, Sendable {
        /// Required (or partly filled), but not all three are set.
        case incomplete
        case invalidRuntime
        case invalidModel
        case invalidReasoning
    }

    public var runtime = ""
    public var model = ""
    public var reasoning: String?

    public init(runtime: String = "", model: String = "", reasoning: String? = nil) {
        self.runtime = runtime
        self.model = model
        self.reasoning = reasoning
    }

    /// Whether starting this template needs the three values.
    public static func isRequired(by template: TemplateInfo) -> Bool {
        template.command.contains("agent-herdr-worker")
    }

    private var trimmedRuntime: String { runtime.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBlank: Bool { trimmedRuntime.isEmpty && trimmedModel.isEmpty && reasoning == nil }

    /// Nil when it may start. Blank is fine unless required; anything typed must be complete.
    public func problem(required: Bool) -> Problem? {
        if isBlank && !required { return nil }
        guard !trimmedRuntime.isEmpty, !trimmedModel.isEmpty, let reasoning else { return .incomplete }
        // The adapter's character rules, so a typo is caught here instead of in its terminal.
        guard Self.matches(trimmedRuntime, extra: "_-") else { return .invalidRuntime }
        guard Self.matches(trimmedModel, extra: "._:+-") else { return .invalidModel }
        guard Self.efforts.contains(reasoning) else { return .invalidReasoning }
        return nil
    }

    /// The labels to start with; empty when left blank.
    public var labels: [String: String] {
        guard !isBlank else { return [:] }
        return [Self.harnessLabel: trimmedRuntime, Self.modelLabel: trimmedModel, Self.effortLabel: reasoning ?? ""]
    }

    private static func matches(_ value: String, extra: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || extra.unicodeScalars.contains($0)
        }
    }
}

extension HerdrCore {
    /// herdr-core's rule (`addr.rs` `check_name`): 1–32 of a-z 0-9 - _ . starting with a
    /// letter or digit, and not shaped like an address such as `t7`.
    public static func isValidTerminalName(_ name: String) -> Bool {
        guard (1...32).contains(name.count),
              let first = name.unicodeScalars.first, isLowerOrDigit(first),
              name.unicodeScalars.allSatisfy({ isLowerOrDigit($0) || "-_.".unicodeScalars.contains($0) })
        else { return false }
        return !isIDShaped(name)
    }

    private static func isLowerOrDigit(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("0"..."9").contains(c)
    }

    /// `t` + a digit 1–9 + herdr's id alphabet: these names are taken by addresses.
    private static func isIDShaped(_ name: String) -> Bool {
        guard name.hasPrefix("t") else { return false }
        let rest = name.dropFirst()
        guard let first = rest.first, ("1"..."9").contains(first) else { return false }
        return rest.allSatisfy { "0123456789bcdfghjkmnpqrstvwxyz".contains($0) }
    }
}

extension HerdrClient {
    /// Starts a terminal; returns once it runs (for a template: once its first message went in
    /// or didn't, see `Terminal.firstMessage`). Cancelling the calling task doesn't end this
    /// wait: the reply (or the connection closing) does. There is no cancel request to send.
    public func run(_ request: RunRequest) async throws -> Terminal {
        try await call("terminal.run", request)
    }

    public func templates() async throws -> [TemplateInfo] {
        let result: TemplatesResult = try await call("templates.list", EmptyParams())
        return result.templates
    }

    /// Ends the program: hangup, then terminate, then kill.
    public func kill(_ address: String) async throws {
        let _: JSONValue = try await call("terminal.kill", TerminalParam(terminal: address))
    }

    /// Sets labels; an empty value removes that label.
    public func label(_ address: String, _ labels: [String: String]) async throws {
        let _: JSONValue = try await call("terminal.label", LabelParams(terminal: address, labels: labels))
    }

    /// Removes a finished terminal from the list.
    public func remove(_ address: String) async throws {
        let _: JSONValue = try await call("terminal.rm", TerminalParam(terminal: address))
    }
}

struct TemplatesResult: Decodable, Sendable {
    let templates: [TemplateInfo]
}

struct LabelParams: Encodable, Sendable {
    let terminal: String
    let labels: [String: String]
}

struct TerminalParam: Encodable, Sendable {
    let terminal: String
}
