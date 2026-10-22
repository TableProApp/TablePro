import Foundation
import TableProSSHTransport

nonisolated enum SSHTunnelError: Error, LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case handshakeFailed(String)
    case authenticationFailed(String)
    case noAvailablePort
    case channelOpenFailed(String)
    case hostKeyRejected(String)
    case hostKeyUnverified(String)
    case usernameMissing(host: String)
    case jumpHostNeedsKey(host: String)
    case jumpHostSharedKeyMissing(host: String)
    case jumpHostFailed(host: String, reason: String)
    case jumpHostKeysUnreadable(String)
    case tunnelClosed
    // jumpHost is nil when the SSH server itself failed.
    case negotiationFailed(SSHNegotiationFailure, jumpHost: String?)
    case securityKeyUnsupported
    case passphraseRequired
    case passphraseIncorrect
    case additionalFactorRequired([String])
    case promptUnanswerable(String)
    case verificationCodeRejected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SSH connection failed: \(msg)"
        case .handshakeFailed(let msg): return "SSH handshake failed: \(msg)"
        case .authenticationFailed(let msg): return "SSH authentication failed: \(msg)"
        case .noAvailablePort: return "No available local port for SSH tunnel"
        case .channelOpenFailed(let msg): return "SSH channel open failed: \(msg)"
        case .hostKeyRejected(let msg): return msg
        case .hostKeyUnverified(let msg): return msg
        case .usernameMissing(let host):
            return String(format: String(localized: "No SSH username is set for %@."), host)
        case .jumpHostNeedsKey(let host):
            return String(format: String(localized: "Jump host %@ has no key on this device."), host)
        case .jumpHostSharedKeyMissing(let host):
            return String(
                format: String(localized: "Jump host %@ uses the SSH server's key, which is not on this device."),
                host
            )
        case .jumpHostFailed(let host, let reason):
            return String(format: String(localized: "Jump host %1$@ failed: %2$@"), host, reason)
        case .jumpHostKeysUnreadable(let reason):
            return String(format: String(localized: "The jump host keys on this device could not be read: %@"), reason)
        case .tunnelClosed: return "SSH tunnel is closed"
        case .negotiationFailed(let failure, let jumpHost):
            guard let jumpHost else { return failure.explanation }
            return String(format: String(localized: "Jump host %1$@ failed: %2$@"), jumpHost, failure.explanation)
        case .securityKeyUnsupported:
            return String(
                localized: "This SSH private key belongs to a security key (FIDO), which TablePro on iPhone and iPad cannot sign with."
            )
        case .passphraseRequired:
            return String(localized: "This SSH private key is encrypted, and no passphrase is saved for it.")
        case .passphraseIncorrect:
            return String(localized: "The passphrase for this SSH private key is incorrect.")
        case .additionalFactorRequired(let methods):
            return String(
                format: String(
                    localized: "The SSH server accepted the first sign-in step and asks for another (%@), which TablePro on iPhone and iPad cannot complete."
                ),
                methods.formatted(.list(type: .or))
            )
        case .promptUnanswerable(let prompt):
            return String(
                format: String(localized: "The SSH server asked “%@”, which TablePro can answer only while it is open."),
                prompt
            )
        case .verificationCodeRejected:
            return String(localized: "The SSH server did not accept the verification code.")
        }
    }
}
