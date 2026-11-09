import Foundation
import HerdrKit
import KeyStore
import SSHTransport

/// Whether connecting again after an error can help. Network trouble is retried; problems a person
/// must fix are not. Above all a rejected login: trying again and again can get the account locked
/// or the address banned. The app adds its own errors on top (HostSession.isRetryable).
public enum Retry {
    public static func makesSense(after error: Error) -> Bool {
        switch error {
        // Retrying would ask for the security key again and again.
        case is SecurityKeyError: return false
        case SSHTransportError.commandFailed, SSHTransportError.authenticationFailed,
             SSHTransportError.passwordRejected, SSHTransportError.hostKeyChanged,
             SSHTransportError.hostKeyRejected:
            return false
        case HerdrError.rpc, HerdrError.invalidResponse: return false
        default:
            // Face ID cancelled, key missing, ... come from LocalAuthentication / CryptoKit.
            let domain = (error as NSError).domain
            return domain != "com.apple.LocalAuthentication" && domain != "CryptoTokenKit"
        }
    }
}
