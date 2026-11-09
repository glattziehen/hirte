import ActivityKit
import Foundation

/// Shared with the extension. Machine and terminal identity never leave the app.
nonisolated struct AgentActivityAttributes: ActivityAttributes {
    let followID: UUID

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case working, needsYou, done, error, ended

            var label: String {
                switch self {
                case .working: "Working"
                case .needsYou: "Needs you"
                case .done: "Done"
                case .error: "Error"
                case .ended: "Ended"
                }
            }
            var symbol: String {
                switch self {
                case .working: "circle.dotted.circle"
                case .needsYou: "person.crop.circle.badge.exclamationmark"
                case .done: "checkmark.circle.fill"
                case .error: "exclamationmark.circle.fill"
                case .ended: "stop.circle"
                }
            }
        }

        var phase: Phase
        var progress: Int?
        var since: Date
        var asOf: Date
        var isLastKnown: Bool
        /// Only populated after explicit permission in Hirte's settings.
        var headline: String?
    }

    var url: URL { URL(string: "hirte://follow/\(followID.uuidString)")! }

    static func followID(from url: URL) -> UUID? {
        guard url.scheme == "hirte", url.host == "follow",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
