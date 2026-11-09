import Foundation

/// Display-only host context transported through the existing terminal labels.
/// The publisher never includes credentials or reads provider authentication files.
public struct TerminalContext: Equatable, Sendable {
    public let branch: String?
    public let project: String?
    public let directory: String?
    public let agent: String?
    public let account: String?

    public init(terminal: Terminal, project: String? = nil) {
        func value(_ string: String?) -> String? {
            guard let string else { return nil }
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        directory = value(terminal.foreground?.cwd) ?? value(terminal.cwd)
        let sameGeneration = terminal.labels["context.created_ms"] == String(terminal.createdMs)
        self.project = value(project) ?? (sameGeneration ? value(terminal.labels["context.project"]) : nil)
        agent = (sameGeneration ? value(terminal.labels["context.agent"]) : nil) ?? value(terminal.status?.app)
        account = sameGeneration ? value(terminal.labels["context.account"]) : nil
        // A branch belongs to a directory and a terminal generation, not just an address.
        let sameDirectory = value(terminal.labels["context.directory"]) == directory
        branch = sameDirectory && sameGeneration ? value(terminal.labels["context.branch"]) : nil
    }
}
