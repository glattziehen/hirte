import Foundation
import KeyStore
import Observation
import SSHTransport

/// A machine running herdr-core that we reach over SSH.
public struct Host: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var target: SSHTarget
    public var keyID: UUID?
    /// Logs in with a password from the Keychain instead of a key.
    /// Optional so hosts saved before it existed still decode.
    public var passwordLogin: Bool?
    /// herdr-core session on that machine (nil: its default).
    public var session: String?
    /// The built-in demo machine: a pretend herdr-core inside the app, no SSH.
    /// Optional so hosts saved before it existed still decode.
    public var demo: Bool?

    public init(
        id: UUID = UUID(), name: String, target: SSHTarget, keyID: UUID? = nil,
        passwordLogin: Bool? = nil, session: String? = nil, demo: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.keyID = keyID
        self.passwordLogin = passwordLogin
        self.session = session
        self.demo = demo
    }

    public var isDemo: Bool { demo == true }

    public var usesPassword: Bool {
        get { passwordLogin == true }
        set { passwordLogin = newValue ? true : nil }
    }

    public var subtitle: String {
        if isDemo { return "Built in · try Hirte without a server" }
        return "\(target.username)@\(target.host)" + (target.port == 22 ? "" : ":\(target.port)")
    }

    /// An empty machine for the editor, with the newest key preselected, or a password without one.
    public static func new(key: UUID?) -> Host {
        Host(name: "", target: SSHTarget(host: "", username: ""), keyID: key, passwordLogin: key == nil ? true : nil)
    }

    public static func makeDemo() -> Host {
        Host(name: "Demo machine", target: SSHTarget(host: "demo", username: "demo"), demo: true)
    }
}

public enum HostStoreError: LocalizedError {
    case passwordNeeded

    public var errorDescription: String? {
        switch self {
        case .passwordNeeded: "Enter the password: the saved one belongs to a different server or user."
        }
    }
}

/// Saved hosts, persisted in UserDefaults. They hold no secrets: passwords are in the Keychain.
@MainActor
@Observable
public final class HostStore {
    public private(set) var hosts: [Host] = []
    /// Raised for a machine each time its password is set, so its session starts over with it.
    public private(set) var passwordRevisions: [UUID: Int] = [:]
    private let defaults: UserDefaults
    private let passwords: PasswordStore
    private let key = "hirte.hosts"

    public init(defaults: UserDefaults = .standard, passwords: PasswordStore = PasswordStore()) {
        self.defaults = defaults
        self.passwords = passwords
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = saved
            prunePasswords()
        } else if defaults.data(forKey: key) == nil {
            // Keychain items outlive the app: none of a previous install's passwords belong here.
            prunePasswords()
        }
    }

    /// Forgets passwords whose machine is gone, say because deleting one failed. Not when the saved
    /// machines couldn't be read: their passwords are still needed.
    private func prunePasswords() {
        guard let machines = try? passwords.machines() else { return }
        for id in machines where !hosts.contains(where: { $0.id == id }) {
            try? passwords.deletePassword(for: id)
        }
    }

    public func save(_ host: Host) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    /// Saves a machine from the editor. `password` is one just typed; nil keeps the saved one, as long
    /// as the machine still points at the server and user it was saved for. A machine that logs in
    /// with a key keeps none.
    public func save(_ host: Host, password: String?) throws {
        if !host.usesPassword {
            // Most key machines never had a password: a Keychain hiccup mustn't stop saving them.
            try? passwords.deletePassword(for: host.id)
        } else if let password {
            try passwords.setPassword(password, for: host.id)
            passwordRevisions[host.id, default: 0] += 1
        } else if !hasPassword(for: host) {
            throw HostStoreError.passwordNeeded
        }
        save(host)
    }

    /// Whether `host` has a saved password it may use: one saved for the server and user it points
    /// at. A password only ever goes where it was typed for.
    public func hasPassword(for host: Host) -> Bool {
        guard let saved = hosts.first(where: { $0.id == host.id }),
              saved.usesPassword, saved.target == host.target else { return false }
        // When the Keychain can't tell, keep what's saved: connecting then reports the real error,
        // rather than the editor asking for a password that is there.
        return (try? passwords.hasPassword(for: host.id)) ?? true
    }

    public var hasDemo: Bool { hosts.contains(where: \.isDemo) }

    /// Adds the demo machine (once) and returns it.
    @discardableResult
    public func addDemo() -> Host {
        if let existing = hosts.first(where: \.isDemo) { return existing }
        let demo = Host.makeDemo()
        save(demo)
        return demo
    }

    public func delete(at offsets: IndexSet) {
        // One that fails is cleaned up on a later launch (prunePasswords).
        for index in offsets { try? passwords.deletePassword(for: hosts[index].id) }
        for index in offsets.reversed() { hosts.remove(at: index) }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(hosts), forKey: key)
    }
}
