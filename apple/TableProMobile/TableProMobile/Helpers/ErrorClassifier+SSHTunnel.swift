import Foundation

// By case, because a translated message may hold none of the words the substring rules look for.
// nil sends the error on to the text rules, which still give timeouts the Local Network recovery.
nonisolated extension ErrorClassifier {
    static func sshTunnelFailure(_ error: SSHTunnelError) -> AppError? {
        switch error {
        case .negotiationFailed:
            return tunnelFailed(
                error,
                recovery: String(localized: "Ask the SSH server's administrator to turn on a method TablePro supports.")
            )
        case .usernameMissing:
            return tunnelFailed(
                error,
                recovery: String(localized: "Edit the connection and enter the username under SSH Server or Jump Hosts.")
            )
        case .jumpHostNeedsKey, .jumpHostSharedKeyMissing:
            return tunnelFailed(
                error,
                recovery: String(localized: "Edit the connection and set a key for this jump host under Jump Hosts.")
            )
        case .jumpHostFailed:
            return tunnelFailed(
                error,
                recovery: String(localized: "Check this jump host's address, port, username and key under Jump Hosts.")
            )
        case .jumpHostKeysUnreadable:
            return tunnelFailed(
                error,
                recovery: String(localized: "Try again. If it keeps failing, update TablePro on this device.")
            )
        case .securityKeyUnsupported:
            return signInUnavailable(
                error,
                recovery: String(localized: "Open this connection in TablePro on the Mac, or edit it and choose a private key that is not on a security key.")
            )
        case .additionalFactorRequired:
            return signInUnavailable(
                error,
                recovery: String(localized: "Open this connection in TablePro on the Mac, which can answer this sign-in step.")
            )
        case .promptUnanswerable:
            return signInUnavailable(
                error,
                recovery: String(localized: "Open this connection in TablePro and connect from there to answer the question.")
            )
        case .verificationCodeRejected:
            return signInRejected(
                error,
                recovery: String(localized: "Check the connection's TOTP secret, and that this device sets its clock automatically.")
            )
        case .passphraseRequired:
            return signInRejected(
                error,
                recovery: String(localized: "Edit the connection and enter the key's passphrase under Private Key.")
            )
        case .passphraseIncorrect:
            return signInRejected(
                error,
                recovery: String(localized: "Edit the connection and check the key's passphrase under Private Key.")
            )
        case .connectionFailed, .handshakeFailed, .authenticationFailed, .noAvailablePort, .channelOpenFailed,
             .hostKeyRejected, .hostKeyUnverified, .tunnelClosed:
            return nil
        }
    }

    private static func tunnelFailed(_ error: SSHTunnelError, recovery: String) -> AppError {
        AppError(
            category: .ssh,
            title: String(localized: "SSH Tunnel Failed"),
            message: error.localizedDescription,
            recovery: recovery,
            underlying: error
        )
    }

    private static func signInUnavailable(_ error: SSHTunnelError, recovery: String) -> AppError {
        AppError(
            category: .config,
            title: String(localized: "SSH Sign-In Unavailable"),
            message: error.localizedDescription,
            recovery: recovery,
            underlying: error
        )
    }

    private static func signInRejected(_ error: SSHTunnelError, recovery: String) -> AppError {
        AppError(
            category: .auth,
            title: String(localized: "SSH Authentication Failed"),
            message: error.localizedDescription,
            recovery: recovery,
            underlying: error
        )
    }
}
