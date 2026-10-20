import Foundation
import TableProModels
import TableProSSHTransport

nonisolated enum SSHTunnelError: Error, LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case handshakeFailed(String)
    case authenticationFailed(String)
    case noAvailablePort
    case channelOpenFailed(String)
    case hostKeyRejected(String)
    case hostKeyUnverified(String)
    case jumpHostsUnsupported
    case tunnelClosed
    case negotiationFailed(SSHNegotiationFailure)
    case authMethodUnsupported(SSHConfiguration.SSHAuthMethod)
    case securityKeyUnsupported
    case passphraseRequired
    case passphraseIncorrect
    case additionalFactorRequired([String])
    case promptUnanswerable(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SSH connection failed: \(msg)"
        case .handshakeFailed(let msg): return "SSH handshake failed: \(msg)"
        case .authenticationFailed(let msg): return "SSH authentication failed: \(msg)"
        case .noAvailablePort: return "No available local port for SSH tunnel"
        case .channelOpenFailed(let msg): return "SSH channel open failed: \(msg)"
        case .hostKeyRejected(let msg): return msg
        case .hostKeyUnverified(let msg): return msg
        case .jumpHostsUnsupported:
            return String(localized: """
                This connection goes through an SSH jump host, which TablePro on iPhone and iPad \
                cannot dial. Open it in TablePro on the Mac.
                """)
        case .tunnelClosed: return "SSH tunnel is closed"
        case .negotiationFailed(let failure):
            return Self.describe(failure)
        case .authMethodUnsupported(let method):
            return String(
                format: String(localized: "TablePro on iPhone and iPad cannot use the SSH authentication method “%@”."),
                Self.name(of: method)
            )
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
                format: String(localized: "The SSH server asked “%@”, which TablePro on iPhone and iPad cannot answer."),
                prompt
            )
        }
    }

    private static func name(of method: SSHConfiguration.SSHAuthMethod) -> String {
        switch method {
        case .password: return String(localized: "Password")
        case .privateKey: return String(localized: "Private Key")
        case .sshAgent: return String(localized: "SSH Agent")
        case .keyboardInteractive: return String(localized: "Keyboard Interactive")
        case .none: return String(localized: "None")
        }
    }

    private static func describe(_ failure: SSHNegotiationFailure) -> String {
        var sentences: [String] = []

        switch failure.stage {
        case .keyExchangeOrHostKey:
            sentences.append(String(localized: "TablePro and the SSH server have no key exchange or host key method in common."))
        case .cipher:
            sentences.append(String(localized: "TablePro and the SSH server have no cipher in common."))
        case .mac:
            sentences.append(String(localized: "TablePro and the SSH server have no MAC algorithm in common."))
        case .undetermined:
            sentences.append(String(localized: "TablePro and the SSH server could not agree on how to encrypt the connection."))
        }

        if let software = failure.serverSoftware {
            sentences.append(String(format: String(localized: "The server runs %@."), software))
        }

        if !failure.supported.isEmpty {
            let list = failure.supported.formatted(.list(type: .and))
            switch failure.stage {
            case .keyExchangeOrHostKey:
                sentences.append(String(format: String(localized: "TablePro supports these key exchange methods: %@."), list))
            case .cipher:
                sentences.append(String(format: String(localized: "TablePro supports these ciphers: %@."), list))
            case .mac:
                sentences.append(String(format: String(localized: "TablePro supports these MAC algorithms: %@."), list))
            case .undetermined:
                break
            }
        }

        if !failure.supportedHostKeys.isEmpty {
            sentences.append(String(
                format: String(localized: "It supports these host key types: %@."),
                failure.supportedHostKeys.formatted(.list(type: .and))
            ))
        }

        return sentences.joined(separator: " ")
    }
}
