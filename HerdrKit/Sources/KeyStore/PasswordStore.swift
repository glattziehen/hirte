import Foundation

/// SSH passwords, one per machine, in the Keychain: never synced or backed up, and readable only
/// while the device is unlocked, which is enough since connections only run in the foreground.
public struct PasswordStore: Sendable {
    private let storage: any KeyStorage

    public init(storage: any KeyStorage = KeychainKeyStorage(service: "hirte.ssh-passwords", whenUnlockedOnly: true)) {
        self.storage = storage
    }

    public func password(for machine: UUID) throws -> String? {
        try storage.load(account: machine.uuidString).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether `machine` has a password, without reading it.
    public func hasPassword(for machine: UUID) throws -> Bool {
        try machines().contains(machine)
    }

    /// The machines that have a password.
    public func machines() throws -> Set<UUID> {
        Set(try storage.accounts().compactMap(UUID.init(uuidString:)))
    }

    public func setPassword(_ password: String, for machine: UUID) throws {
        try storage.save(Data(password.utf8), account: machine.uuidString)
    }

    public func deletePassword(for machine: UUID) throws {
        try storage.delete(account: machine.uuidString)
    }
}
