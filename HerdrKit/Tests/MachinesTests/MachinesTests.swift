import Foundation
import HerdrKit
import KeyStore
import Machines
import SSHTransport
import Testing

/// Foundation has a `Host` too, on macOS.
private typealias Host = Machines.Host

@MainActor
struct HostTests {
    @Test func subtitleShowsPortOnlyWhenNotDefault() {
        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        #expect(host.subtitle == "pavel@mini.local")
        host.target.port = 2222
        #expect(host.subtitle == "pavel@mini.local:2222")
    }

    @Test func hostsSavedBeforeTheDemoExistedStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Mini","target":{"host":"mini.local","port":22,"username":"pavel"}}]"#
        let hosts = try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        #expect(hosts.first?.isDemo == false)
    }

    @Test func storePersistsAndAddsTheDemoOnce() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HostStore(defaults: defaults)
        store.save(Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel")))
        let demo = store.addDemo()
        #expect(store.addDemo().id == demo.id)

        let reloaded = HostStore(defaults: defaults)
        #expect(reloaded.hosts.map(\.name) == ["Mini", "Demo machine"])
        #expect(reloaded.hasDemo)
    }

    @Test func hostsSavedBeforePasswordsLogInWithTheirKey() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Mini","target":{"host":"mini.local","port":22,"username":"pavel"}}]"#
        let hosts = try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        #expect(hosts.first?.usesPassword == false)
    }

    @Test func aNewMachineUsesItsKeyOrElseAPassword() {
        #expect(Host.new(key: UUID()).usesPassword == false)
        #expect(Host.new(key: nil).usesPassword)
    }

    @Test func passwordsStayOutOfTheSavedHostsAndGoWithTheirMachine() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let passwords = PasswordStore(storage: InMemoryKeyStorage())
        let store = HostStore(defaults: defaults, passwords: passwords)

        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        host.usesPassword = true
        try store.save(host, password: "correct horse")
        #expect(try passwords.password(for: host.id) == "correct horse")
        #expect(store.hasPassword(for: host))
        let saved = try #require(defaults.data(forKey: "hirte.hosts"))
        #expect(!String(decoding: saved, as: UTF8.self).contains("correct horse"))

        // Saving without typing one keeps it.
        try store.save(host, password: nil)
        #expect(try passwords.password(for: host.id) == "correct horse")

        // It only goes to the server and user it was saved for.
        var moved = host
        moved.target.host = "other.local"
        #expect(!store.hasPassword(for: moved))
        #expect(throws: HostStoreError.self) { try store.save(moved, password: nil) }
        #expect(store.hosts.first?.target.host == "mini.local")
        let revision = store.passwordRevisions[host.id]
        try store.save(moved, password: "for other")
        #expect(store.hasPassword(for: moved))
        #expect(store.passwordRevisions[host.id] != revision)
        host = moved

        // Moving to a key forgets it, and so does deleting the machine.
        host.usesPassword = false
        try store.save(host, password: "ignored")
        #expect(try passwords.password(for: host.id) == nil)
        host.usesPassword = true
        try store.save(host, password: "battery staple")
        store.delete(at: [0])
        #expect(try passwords.password(for: host.id) == nil)
    }
}

extension HostTests {
    /// A password left behind (a delete that failed, a previous install) goes on the next launch.
    @Test func leftoverPasswordsAreForgotten() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let passwords = PasswordStore(storage: InMemoryKeyStorage())
        let orphan = UUID()
        try passwords.setPassword("left behind", for: orphan)

        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        host.usesPassword = true
        try HostStore(defaults: defaults, passwords: passwords).save(host, password: "kept")
        #expect(try passwords.machines() == [host.id])

        try passwords.setPassword("left behind", for: orphan)
        _ = HostStore(defaults: defaults, passwords: passwords)
        #expect(try passwords.machines() == [host.id])

        // Saved machines that can't be read keep their passwords.
        defaults.set(Data("not json".utf8), forKey: "hirte.hosts")
        _ = HostStore(defaults: defaults, passwords: passwords)
        #expect(try passwords.hasPassword(for: host.id))
    }
}

struct RetryTests {
    /// Trying a rejected login again and again can get the account locked or the address banned.
    @Test func aRejectedLoginIsNotRetried() {
        #expect(!Retry.makesSense(after: SSHTransportError.passwordRejected(username: "me")))
        #expect(!Retry.makesSense(after: SSHTransportError.authenticationFailed(username: "me")))
    }

    @Test func problemsAPersonMustFixAreNotRetried() {
        #expect(!Retry.makesSense(after: SSHTransportError.hostKeyChanged(host: "mini", expected: "a", offered: "b")))
        #expect(!Retry.makesSense(after: SSHTransportError.hostKeyRejected(host: "mini")))
        #expect(!Retry.makesSense(after: SSHTransportError.commandFailed(exitCode: 127, stderr: "")))
        #expect(!Retry.makesSense(after: HerdrError.invalidResponse("garbage")))
        #expect(!Retry.makesSense(after: SecurityKeyError.invalidSignature))
        // Face ID cancelled
        #expect(!Retry.makesSense(after: NSError(domain: "com.apple.LocalAuthentication", code: -2)))
    }

    @Test func networkTroubleIsRetried() {
        #expect(Retry.makesSense(after: URLError(.networkConnectionLost)))
        #expect(Retry.makesSense(after: POSIXError(.ECONNRESET)))
    }
}
