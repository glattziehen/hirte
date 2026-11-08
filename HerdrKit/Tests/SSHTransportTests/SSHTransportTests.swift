import CryptoKit
import Foundation
import KeyStore
import NIOEmbedded
@preconcurrency import NIOSSH
import Testing
@testable import SSHTransport

@Test func authorizedKeysLineParsesInNIOSSH() {
    let key = P256.Signing.PrivateKey().publicKey
    let line = OpenSSH.authorizedKeysLine(key, comment: "phone")
    let parts = line.split(separator: " ")
    #expect(normalizedOpenSSHPublicKey(line) == "\(parts[0]) \(parts[1])")
}

@Test func aRejectionNamesWhatWasRejected() throws {
    let key = try #require(SSHCredential.key(.p256(P256.Signing.PrivateKey())).rejected(username: "me").errorDescription)
    #expect(key.contains("key for me"))
    let password = try #require(SSHCredential.password("correct horse").rejected(username: "me").errorDescription)
    #expect(password.contains("password for me"))
    #expect(!password.contains("correct horse"))
}

/// A wrong password must not be sent twice, and none goes to a server that doesn't take passwords.
@Test func aPasswordIsOfferedOnceAndOnlyWhereTaken() throws {
    let loop = EmbeddedEventLoop()
    func ask(_ auth: SingleOfferAuthentication, _ methods: NIOSSHAvailableUserAuthenticationMethods) throws -> NIOSSHUserAuthenticationOffer? {
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        auth.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise)
        loop.run()
        return try promise.futureResult.wait()
    }
    func password() -> SingleOfferAuthentication {
        SingleOfferAuthentication(
            username: "me", method: .password, offer: .password(.init(password: "pw")),
            rejected: .passwordRejected(username: "me"))
    }

    let auth = password()
    #expect(try ask(auth, .all) != nil)
    #expect(throws: SSHTransportError.self) { try ask(auth, .all) }
    #expect(throws: SSHTransportError.self) { try ask(password(), .publicKey) }
}

@Test func knownHostsNames() {
    #expect(SSHTarget(host: "box", username: "me").knownHostsName == "box")
    #expect(SSHTarget(host: "box", port: 2222, username: "me").knownHostsName == "[box]:2222")
}

@Test func inMemoryKnownHosts() {
    let hosts = InMemoryKnownHosts()
    #expect(hosts.hostKey(for: "box") == nil)
    hosts.setHostKey("ssh-ed25519 AAAA", for: "box")
    #expect(hosts.hostKey(for: "box") == "ssh-ed25519 AAAA")
    hosts.removeHostKey(for: "box")
    #expect(hosts.hostKey(for: "box") == nil)
}

#if os(macOS)
// MARK: - Logging in to a real sshd

/// A throwaway sshd on localhost that lets the current user in with the given keys.
private final class LocalSSHD {
    let directory: URL
    let port = Int.random(in: 20_000..<60_000)
    private let process = Process()
    private let log: URL

    init(authorizedKeys: [String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hirte-sshd-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostKey = directory.appendingPathComponent("host")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path]
        try keygen.run()
        keygen.waitUntilExit()
        try authorizedKeys.joined(separator: "\n")
            .write(to: directory.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        let config = """
            ListenAddress 127.0.0.1
            Port \(port)
            HostKey \(hostKey.path)
            AuthorizedKeysFile \(directory.appendingPathComponent("authorized_keys").path)
            PidFile \(directory.appendingPathComponent("pid").path)
            UsePAM no
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAcceptedAlgorithms +webauthn-sk-ecdsa-sha2-nistp256@openssh.com
            LogLevel DEBUG1
            """
        try config.write(to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        log = directory.appendingPathComponent("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", directory.appendingPathComponent("config").path]
        let handle = try FileHandle(forWritingTo: log)
        process.standardError = handle
        process.standardOutput = handle
        try process.run()
        // Wait until it listens.
        for _ in 0..<50 where !((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("Server listening") {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    var output: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    func stop() {
        process.terminate()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeKeys() throws -> [(String, SigningKey)] {
    var keys: [(String, SigningKey)] = [
        ("ed25519", .ed25519(Curve25519.Signing.PrivateKey())),
        ("p256", .p256(P256.Signing.PrivateKey())),
        ("p384", .p384(P384.Signing.PrivateKey())),
        ("p521", .p521(P521.Signing.PrivateKey())),
    ]
    let rsaFile = FileManager.default.temporaryDirectory.appendingPathComponent("hirte-rsa-\(UUID())")
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", rsaFile.path]
    try keygen.run()
    keygen.waitUntilExit()
    let rsa = try PrivateKeyParser.parse(try String(contentsOf: rsaFile, encoding: .utf8))
    let store = KeyStore(storage: InMemoryKeyStorage())
    keys.append(("rsa", try store.signingKey(for: try store.importKey(rsa, label: "rsa").id)))

    // A software stand-in for a security key, answering the way WebAuthn does.
    let secret = P256.Signing.PrivateKey()
    let application = "hirte.dev"
    var blob = Data()
    func string(_ bytes: Data) {
        withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { blob.append(contentsOf: $0) }
        blob.append(bytes)
    }
    string(Data("sk-ecdsa-sha2-nistp256@openssh.com".utf8))
    string(Data("nistp256".utf8))
    string(secret.publicKey.x963Representation)
    string(Data(application.utf8))
    let signer = try SecurityKeySigner(publicKeyBlob: blob, credentialID: Data([1, 2, 3])) { _, challenge in
        try await Task.sleep(for: .milliseconds(200))  // the user taps the key
        let encoded = challenge.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let clientData = Data(
            #"{"type":"webauthn.get","challenge":"\#(encoded)","origin":"https://\#(application)","crossOrigin":false}"#.utf8)
        var authData = Data(SHA256.hash(data: Data(application.utf8)))
        authData.append(contentsOf: [0x01, 0, 0, 0, 42])
        let signature = try secret.signature(for: authData + Data(SHA256.hash(data: clientData)))
        return WebAuthnAssertion(
            authenticatorData: authData, clientDataJSON: clientData, signature: signature.derRepresentation)
    }
    keys.append(("security key", .securityKey(signer)))
    return keys
}

/// Every kind of key logs in to OpenSSH's sshd.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")))
func logsInToSSHD() async throws {
    let keys = try makeKeys()
    let lines = keys.map { name, key in
        let blob = key.publicKeyBlob
        let type = String(decoding: blob[4..<(4 + Int(blob[3]))], as: UTF8.self)
        return "\(type) \(blob.base64EncodedString()) \(name)"
    }
    let sshd = try LocalSSHD(authorizedKeys: lines)
    defer { sshd.stop() }
    let target = SSHTarget(host: "127.0.0.1", port: sshd.port, username: NSUserName())

    for (name, key) in keys {
        do {
            let connection = try await SSHConnection.connect(
                to: target, credential: .key(key), knownHosts: InMemoryKnownHosts(), onUnknownHost: { _ in true })
            let output = try await connection.run("echo hello")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello", "\(name)")
            await connection.close()
        } catch {
            Issue.record("\(name) failed: \(error)\nsshd said:\n\(sshd.output.suffix(1500))")
        }
    }
    // sshd's own word that each key type got in.
    let accepted = sshd.output.components(separatedBy: .newlines).filter { $0.contains("Accepted publickey for") }
    for type in ["ED25519", "ECDSA ", "RSA", "ECDSA-SK"] {
        #expect(accepted.contains { $0.contains(": \(type)") }, "\(type) not accepted")
    }
    #expect(accepted.count == keys.count, "\(accepted)")
}
#endif

#if os(macOS)
struct TappedCancel: Error {}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")))
func securityKeyErrorReachesTheCaller() async throws {
    let keys = try makeKeys()
    guard case .securityKey(let original) = keys.last?.1 else { return }
    let failing = try SecurityKeySigner(publicKeyBlob: original.publicKeyBlob, credentialID: Data([1])) { _, _ in
        throw TappedCancel()
    }
    let sshd = try LocalSSHD(authorizedKeys: [])
    defer { sshd.stop() }
    let target = SSHTarget(host: "127.0.0.1", port: sshd.port, username: NSUserName())
    await #expect(throws: TappedCancel.self) {
        _ = try await SSHConnection.connect(
            to: target, credential: .key(.securityKey(failing)), knownHosts: InMemoryKnownHosts(), onUnknownHost: { _ in true })
    }
}
#endif
