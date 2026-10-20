import Foundation

// nil sends the error on to the text rules, which still give timeouts the Local Network recovery.
nonisolated extension ErrorClassifier {
    static func sshTunnelFailure(_ error: SSHTunnelError) -> AppError? {
        switch error {
        case .negotiationFailed:
            return AppError(
                category: .ssh,
                title: String(localized: "SSH Tunnel Failed"),
                message: error.localizedDescription,
                recovery: String(localized: "Ask the SSH server's administrator to turn on a method TablePro supports."),
                underlying: error
            )
        case .authMethodUnsupported:
            return signInUnavailable(
                error,
                recovery: String(localized: "Open this connection in TablePro on the Mac, or edit it and choose Password or Private Key.")
            )
        case .securityKeyUnsupported:
            return signInUnavailable(
                error,
                recovery: String(localized: "Open this connection in TablePro on the Mac, or edit it and choose a private key that is not on a security key.")
            )
        case .additionalFactorRequired, .promptUnanswerable:
            return signInUnavailable(
                error,
                recovery: String(localized: "Open this connection in TablePro on the Mac, which can answer this sign-in step.")
            )
        case .passphraseRequired:
            return passphraseFailure(
                error,
                recovery: String(localized: "Edit the connection and enter the key's passphrase under Private Key.")
            )
        case .passphraseIncorrect:
            return passphraseFailure(
                error,
                recovery: String(localized: "Edit the connection and check the key's passphrase under Private Key.")
            )
        case .connectionFailed, .handshakeFailed, .authenticationFailed, .noAvailablePort, .channelOpenFailed,
             .hostKeyRejected, .hostKeyUnverified, .jumpHostsUnsupported, .tunnelClosed:
            return nil
        }
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

    private static func passphraseFailure(_ error: SSHTunnelError, recovery: String) -> AppError {
        AppError(
            category: .auth,
            title: String(localized: "SSH Authentication Failed"),
            message: error.localizedDescription,
            recovery: recovery,
            underlying: error
        )
    }
}
