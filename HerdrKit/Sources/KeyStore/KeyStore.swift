import CryptoKit
import Foundation
import LocalAuthentication
import Security
import _CryptoExtras

/// Where the private key lives.
public enum SSHKeyKind: String, Codable, Sendable {
    /// Generated inside the Secure Enclave; the private key never leaves the chip.
    case secureEnclave
    /// A private key stored in the Keychain: generated here (Ed25519, or P-256 where there is no
    /// Secure Enclave) or imported.
    case software
    /// A FIDO2 security key, used through WebAuthn; the private key never leaves the security key.
    case securityKey
}

/// The SSH public key algorithm.
public enum SSHKeyAlgorithm: String, Codable, Sendable, CaseIterable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
    case rsa = "ssh-rsa"
    case securityKeyP256 = "sk-ecdsa-sha2-nistp256@openssh.com"

    /// The curve as SSH names it, for ECDSA keys.
    var curveName: String? {
        switch self {
        case .ecdsaP256, .securityKeyP256: "nistp256"
        case .ecdsaP384: "nistp384"
        case .ecdsaP521: "nistp521"
        case .ed25519, .rsa: nil
        }
    }

    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        case .rsa: "RSA"
        case .securityKeyP256: "ECDSA-SK P-256"
        }
    }
}

/// Public facts about a stored key. Safe to show and pass around.
public struct SSHKeyInfo: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public let kind: SSHKeyKind
    /// Face ID before each use. Enforced by the Secure Enclave for its keys; by the app for others.
    public let requiresBiometry: Bool
    public let createdAt: Date
    /// The public key in SSH wire format (what `authorized_keys` holds, base64-encoded).
    public let publicKeyBlob: Data
    /// Made elsewhere and imported, rather than generated on this device.
    public let isImported: Bool

    public init(
        id: UUID = UUID(), label: String, kind: SSHKeyKind, requiresBiometry: Bool = false,
        createdAt: Date = Date(), publicKeyBlob: Data, isImported: Bool = false
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.requiresBiometry = requiresBiometry
        self.createdAt = createdAt
        self.publicKeyBlob = publicKeyBlob
        self.isImported = isImported
    }

    public var algorithm: SSHKeyAlgorithm? {
        OpenSSH.keyType(ofBlob: publicKeyBlob).flatMap(SSHKeyAlgorithm.init(rawValue:))
    }

    /// The modulus size of an RSA key.
    public var rsaBits: Int? {
        guard algorithm == .rsa else { return nil }
        var reader = SSHReader(publicKeyBlob)
        guard (try? reader.string()) != nil, (try? reader.mpint()) != nil,
              let n = try? reader.mpint(), let first = n.first
        else { return nil }
        return (n.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    /// e.g. "Ed25519" or "RSA 4096".
    public var algorithmDescription: String {
        guard let algorithm else { return OpenSSH.keyType(ofBlob: publicKeyBlob) ?? "Unknown" }
        if let bits = rsaBits { return "\(algorithm.displayName) \(bits)" }
        return algorithm.displayName
    }

    /// Paste this into `~/.ssh/authorized_keys` on the server.
    public var authorizedKeysLine: String {
        OpenSSH.authorizedKeysLine(blob: publicKeyBlob, comment: label)
    }

    public var fingerprint: String {
        OpenSSH.sha256Fingerprint(blob: publicKeyBlob)
    }
}

extension SSHKeyInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, label, kind, requiresBiometry, createdAt, publicKeyBlob, isImported
        /// Before other key types existed, only a P-256 point was stored.
        case publicKeyX963
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        kind = try container.decode(SSHKeyKind.self, forKey: .kind)
        requiresBiometry = try container.decode(Bool.self, forKey: .requiresBiometry)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isImported = try container.decodeIfPresent(Bool.self, forKey: .isImported) ?? false
        if let blob = try container.decodeIfPresent(Data.self, forKey: .publicKeyBlob) {
            publicKeyBlob = blob
        } else {
            let x963 = try container.decode(Data.self, forKey: .publicKeyX963)
            publicKeyBlob = OpenSSH.publicKeyBlob(try P256.Signing.PublicKey(x963Representation: x963))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(kind, forKey: .kind)
        try container.encode(requiresBiometry, forKey: .requiresBiometry)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(publicKeyBlob, forKey: .publicKeyBlob)
        try container.encode(isImported, forKey: .isImported)
    }
}

/// A private key ready to sign an SSH login.
public enum SigningKey: @unchecked Sendable {
    case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(_RSA.Signing.PrivateKey)
    case securityKey(SecurityKeySigner)

    var algorithm: SSHKeyAlgorithm {
        switch self {
        case .secureEnclave, .p256: .ecdsaP256
        case .p384: .ecdsaP384
        case .p521: .ecdsaP521
        case .ed25519: .ed25519
        case .rsa: .rsa
        case .securityKey: .securityKeyP256
        }
    }

    /// The public key in SSH wire format.
    public var publicKeyBlob: Data {
        switch self {
        case .secureEnclave(let key): OpenSSH.publicKeyBlob(key.publicKey)
        case .p256(let key): OpenSSH.publicKeyBlob(key.publicKey)
        case .p384(let key): OpenSSH.ecdsaBlob(type: .ecdsaP384, point: key.publicKey.x963Representation)
        case .p521(let key): OpenSSH.ecdsaBlob(type: .ecdsaP521, point: key.publicKey.x963Representation)
        case .ed25519(let key): OpenSSH.ed25519Blob(key.publicKey)
        case .rsa(let key): OpenSSHRSA.publicKeyBlob(key)
        case .securityKey(let signer): signer.publicKeyBlob
        }
    }
}

public enum KeyStoreError: Error, LocalizedError {
    case notFound(UUID)
    case secureEnclaveUnavailable
    case keychain(OSStatus)
    case accessControl(String)
    case noSecurityKeyAuthenticator

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "No key with id \(id)."
        case .secureEnclaveUnavailable: "This device has no Secure Enclave."
        case .keychain(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        case .accessControl(let message): "Could not set up key access control: \(message)"
        case .noSecurityKeyAuthenticator: "Security keys can't be used here."
        }
    }
}

/// Creates, imports, lists and loads SSH keys.
///
/// Secure Enclave keys are stored as their `dataRepresentation`: an opaque
/// handle that only this device's Secure Enclave can use. Security keys are stored
/// as their WebAuthn credential ID; the private key stays on the security key.
public final class KeyStore: Sendable {
    private let storage: any KeyStorage

    public init(storage: any KeyStorage = KeychainKeyStorage()) {
        self.storage = storage
    }

    public static var isSecureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    public func keys() throws -> [SSHKeyInfo] {
        try records().map(\.info).sorted { $0.createdAt < $1.createdAt }
    }

    /// Creates a P-256 key in the Secure Enclave, or a software key where there is none
    /// (the simulator) and `allowSoftwareFallback` is set.
    @discardableResult
    public func generateKey(
        label: String,
        requireBiometry: Bool = false,
        allowSoftwareFallback: Bool = true
    ) throws -> SSHKeyInfo {
        let record: StoredKey
        if Self.isSecureEnclaveAvailable {
            let flags: SecAccessControlCreateFlags =
                requireBiometry ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage]
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error
            ) else {
                throw KeyStoreError.accessControl(
                    error.map { "\($0.takeRetainedValue())" } ?? "unknown")
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            record = StoredKey(
                info: SSHKeyInfo(
                    label: label, kind: .secureEnclave, requiresBiometry: requireBiometry,
                    publicKeyBlob: OpenSSH.publicKeyBlob(key.publicKey)),
                keyData: key.dataRepresentation)
        } else if allowSoftwareFallback {
            let key = P256.Signing.PrivateKey()
            record = StoredKey(
                info: SSHKeyInfo(label: label, kind: .software, publicKeyBlob: OpenSSH.publicKeyBlob(key.publicKey)),
                keyData: key.rawRepresentation)
        } else {
            throw KeyStoreError.secureEnclaveUnavailable
        }
        try save(record)
        return record.info
    }

    /// Creates an Ed25519 key, stored in the Keychain.
    @discardableResult
    public func generateEd25519Key(label: String, requireBiometry: Bool = false) throws -> SSHKeyInfo {
        let key = Curve25519.Signing.PrivateKey()
        let record = StoredKey(
            info: SSHKeyInfo(
                label: label, kind: .software, requiresBiometry: requireBiometry,
                publicKeyBlob: OpenSSH.ed25519Blob(key.publicKey)),
            keyData: key.rawRepresentation)
        try save(record)
        return record.info
    }

    /// Stores a private key read with `PrivateKeyParser`, in the Keychain.
    @discardableResult
    public func importKey(_ key: ParsedPrivateKey, label: String, requireBiometry: Bool = false) throws -> SSHKeyInfo {
        let record = StoredKey(
            info: SSHKeyInfo(
                label: label, kind: .software, requiresBiometry: requireBiometry,
                publicKeyBlob: key.publicKeyBlob, isImported: true),
            keyData: key.keyData)
        try save(record)
        return record.info
    }

    /// Remembers a security key registered with `SecurityKeyRegistration`.
    @discardableResult
    public func addSecurityKey(_ registration: SecurityKeyRegistration, label: String) throws -> SSHKeyInfo {
        let record = StoredKey(
            info: SSHKeyInfo(label: label, kind: .securityKey, publicKeyBlob: registration.publicKeyBlob),
            keyData: registration.credentialID)
        try save(record)
        return record.info
    }

    /// Loads the private key for signing.
    ///
    /// For a key that requires biometry, pass an `LAContext` that already passed
    /// `evaluatePolicy`, so signing does not prompt in the middle of the SSH handshake.
    /// For a security key, pass what asks it to sign (`assert`).
    public func signingKey(
        for id: UUID,
        authenticationContext: LAContext? = nil,
        securityKeyAssertion assert: SecurityKeySigner.Assert? = nil
    ) throws -> SigningKey {
        guard let record = try records().first(where: { $0.info.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        switch record.info.kind {
        case .secureEnclave:
            return .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: record.keyData, authenticationContext: authenticationContext))
        case .software:
            return try PrivateKeyParser.signingKey(
                algorithm: record.info.algorithm, keyData: record.keyData)
        case .securityKey:
            guard let assert else { throw KeyStoreError.noSecurityKeyAuthenticator }
            return .securityKey(try SecurityKeySigner(
                publicKeyBlob: record.info.publicKeyBlob, credentialID: record.keyData, assert: assert))
        }
    }

    public func rename(id: UUID, to label: String) throws {
        guard var record = try records().first(where: { $0.info.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        record.info.label = label
        try save(record)
    }

    public func deleteKey(id: UUID) throws {
        try storage.delete(account: id.uuidString)
    }

    private func save(_ record: StoredKey) throws {
        try storage.save(try JSONEncoder().encode(record), account: record.info.id.uuidString)
    }

    private func records() throws -> [StoredKey] {
        // Skip entries we cannot read rather than hiding every key.
        try storage.loadAll().compactMap { try? JSONDecoder().decode(StoredKey.self, from: $0) }
    }
}

struct StoredKey: Codable {
    var info: SSHKeyInfo
    /// Secure Enclave handle, the private key (see `PrivateKeyParser.signingKey`) or a
    /// security key's credential ID.
    var keyData: Data
}

// MARK: - Storage

/// Persists opaque key records.
public protocol KeyStorage: Sendable {
    func loadAll() throws -> [Data]
    func load(account: String) throws -> Data?
    /// The accounts that have a record, without reading (or decrypting) the records.
    func accounts() throws -> [String]
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// Generic-password items in the data protection keychain, never synced off the device.
public struct KeychainKeyStorage: KeyStorage {
    public let service: String
    /// Readable only while the device is unlocked, not from its first unlock on.
    private let whenUnlockedOnly: Bool

    public init(service: String = "hirte.ssh-keys", whenUnlockedOnly: Bool = false) {
        self.service = service
        self.whenUnlockedOnly = whenUnlockedOnly
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func loadAll() throws -> [Data] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecValueData as String] as? Data }
    }

    public func load(account: String) throws -> Data? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        return result as? Data
    }

    public func accounts() throws -> [String] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func save(_ data: Data, account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = whenUnlockedOnly
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    public func delete(account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychain(status)
        }
    }
}

/// For tests and previews.
public final class InMemoryKeyStorage: KeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func loadAll() throws -> [Data] { lock.withLock { Array(items.values) } }
    public func load(account: String) throws -> Data? { lock.withLock { items[account] } }
    public func accounts() throws -> [String] { lock.withLock { Array(items.keys) } }
    public func save(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
}
