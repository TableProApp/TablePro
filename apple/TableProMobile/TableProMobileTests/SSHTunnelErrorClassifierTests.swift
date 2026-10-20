import Foundation
import TableProModels
import TableProSSHTransport
import Testing

@testable import TableProMobile

struct SSHTunnelErrorClassifierTests {
    private static let context = ErrorContext(operation: "connect", host: "db.example.com", sshEnabled: true)

    static let fallThrough: [SSHTunnelError] = [
        .connectionFailed("Connection timed out"),
        .handshakeFailed("Failed getting banner"),
        .authenticationFailed("Authentication failed (username/password)"),
        .noAvailablePort,
        .channelOpenFailed("Channel open failure"),
        .hostKeyRejected("The server's host key was not trusted."),
        .hostKeyUnverified("The server's host key could not be checked."),
        .tunnelClosed,
    ]

    @Test("A key exchange failure gets the negotiation recovery, not the credentials one")
    func keyExchangeFailureIsNotACredentialsProblem() {
        let failure = SSHNegotiationFailure(
            stage: .keyExchangeOrHostKey,
            serverSoftware: "OpenSSH_10.3",
            supported: ["curve25519-sha256", "ecdh-sha2-nistp256"],
            supportedHostKeys: ["ssh-ed25519", "rsa-sha2-512"]
        )

        let error = ErrorClassifier.classify(SSHTunnelError.negotiationFailed(failure), context: Self.context)

        #expect(error.category == .ssh)
        #expect(error.recovery == String(localized: "Ask the SSH server's administrator to turn on a method TablePro supports."))
        #expect(error.recovery != String(localized: "Check your SSH username, password, or private key."))
        #expect(error.message.contains("OpenSSH_10.3"))
        #expect(error.message.contains("curve25519-sha256"))
        #expect(error.message.contains("rsa-sha2-512"))
    }

    @Test("An SSH connect that timed out keeps the Local Network recovery")
    func connectTimeoutKeepsTheLocalNetworkRecovery() {
        let error = ErrorClassifier.classify(SSHTunnelError.connectionFailed("Connection timed out"), context: Self.context)

        #expect(error.category == .network)
        #expect(error.recovery == String(
            localized: "Local Network access may be blocked. Open Settings > Privacy & Security > Local Network and turn TablePro on."
        ))
    }

    @Test("A rejected host key keeps its title")
    func rejectedHostKeyKeepsItsTitle() {
        let error = ErrorClassifier.classify(
            SSHTunnelError.hostKeyRejected(String(localized: "The server's host key was not trusted.")),
            context: Self.context
        )

        #expect(error.category == .system)
        #expect(error.title == String(localized: "Error"))
    }

    @Test("Only the named cases are classified by case", arguments: SSHTunnelErrorClassifierTests.fallThrough)
    func olderCasesFallThrough(error: SSHTunnelError) {
        #expect(ErrorClassifier.sshTunnelFailure(error) == nil)
    }

    @Test("An auth method iOS cannot use is named and points to the Mac")
    func unsupportedMethodPointsToTheMac() {
        let error = ErrorClassifier.classify(
            SSHTunnelError.authMethodUnsupported(.keyboardInteractive),
            context: Self.context
        )

        #expect(error.category == .config)
        #expect(error.title == String(localized: "SSH Sign-In Unavailable"))
        #expect(error.message.contains(String(localized: "Keyboard Interactive")))
        #expect(error.recovery == String(
            localized: "Open this connection in TablePro on the Mac, or edit it and choose Password or Private Key."
        ))
    }

    @Test("A security key points to the Mac")
    func securityKeyPointsToTheMac() {
        let error = ErrorClassifier.classify(SSHTunnelError.securityKeyUnsupported, context: Self.context)

        #expect(error.category == .config)
        #expect(error.recovery == String(
            localized: "Open this connection in TablePro on the Mac, or edit it and choose a private key that is not on a security key."
        ))
    }

    @Test(
        "A second sign-in step is not read as a wrong credential",
        arguments: [SSHTunnelError.additionalFactorRequired(["keyboard-interactive"]), .promptUnanswerable("Verification code:")]
    )
    func secondStepPointsToTheMac(error tunnelError: SSHTunnelError) {
        let error = ErrorClassifier.classify(tunnelError, context: Self.context)

        #expect(error.category == .config)
        #expect(error.title == String(localized: "SSH Sign-In Unavailable"))
        #expect(error.recovery == String(localized: "Open this connection in TablePro on the Mac, which can answer this sign-in step."))
    }

    @Test("A missing passphrase names the key's passphrase")
    func missingPassphrase() {
        let error = ErrorClassifier.classify(SSHTunnelError.passphraseRequired, context: Self.context)

        #expect(error.category == .auth)
        #expect(error.recovery == String(localized: "Edit the connection and enter the key's passphrase under Private Key."))
    }

    @Test("A wrong passphrase names the key's passphrase")
    func wrongPassphrase() {
        let error = ErrorClassifier.classify(SSHTunnelError.passphraseIncorrect, context: Self.context)

        #expect(error.category == .auth)
        #expect(error.recovery == String(localized: "Edit the connection and check the key's passphrase under Private Key."))
    }
}
