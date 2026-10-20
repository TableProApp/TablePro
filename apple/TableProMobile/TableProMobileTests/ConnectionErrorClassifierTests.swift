import Foundation
import TableProDatabase
@testable import TableProMobile
import Testing

@Suite("Connection error classification")
struct ConnectionErrorClassifierTests {
    @Test("A previous session still closing keeps its own category, whatever words its message holds")
    func stillClosingIsNotReadAsText() {
        let error = ErrorClassifier.classify(
            ConnectionError.previousSessionStillClosing,
            context: ErrorContext(operation: "connect", host: "db.example.com", sshEnabled: true)
        )

        #expect(error.category == .system)
        #expect(error.title == String(localized: "Still Closing"))
        #expect(error.message == String(localized: "The previous session has not finished closing."))
        #expect(error.recovery == String(localized: "Tap Retry in a moment."))
    }

    @Test("SSH being unavailable is a configuration problem, not a tunnel that failed")
    func sshNotSupportedIsConfiguration() {
        let error = ErrorClassifier.classify(
            ConnectionError.sshNotSupported,
            context: ErrorContext(operation: "connect")
        )

        #expect(error.category == .config)
        #expect(error.title == String(localized: "SSH Unavailable"))
        #expect(error.recovery == String(localized: "Turn off the SSH tunnel for this connection."))
    }

    @Test("A Mac socket connection is a configuration problem that points back to the Mac")
    func localSocketIsConfiguration() {
        let error = ErrorClassifier.classify(
            ConnectionError.localSocketNotSupported,
            context: ErrorContext(operation: "connect", host: "localhost")
        )

        #expect(error.category == .config)
        #expect(error.title == String(localized: "Socket Unavailable"))
        #expect(error.message == ConnectionError.localSocketNotSupported.localizedDescription)
        #expect(error.recovery == String(localized: "Open it on the Mac, or change it there to connect by host and port."))
    }

    @Test("A type with no driver here points to the Mac and names the type")
    func driverNotFoundPointsToTheMac() {
        let error = ErrorClassifier.classify(
            ConnectionError.driverNotFound("Cassandra"),
            context: ErrorContext(operation: "connect")
        )

        #expect(error.category == .config)
        #expect(error.title == String(localized: "Opens on Mac Only"))
        #expect(error.message.contains("Cassandra"))
        #expect(error.recovery == String(localized: "Open it in TablePro on your Mac."))
    }

    @Test(
        "A refusal from the device offers no Retry",
        arguments: [ConnectionError.driverNotFound("MongoDB"), .localSocketNotSupported]
    )
    func refusalCannotRetry(_ refusal: ConnectionError) {
        #expect(!ErrorClassifier.connectionFailure(refusal).canRetry)
    }

    @Test("A session that is gone can be retried")
    func notConnectedCanRetry() {
        #expect(ErrorClassifier.connectionFailure(.notConnected).canRetry)
    }

    @Test("A session that is gone is reported with a way back")
    func notConnectedOffersAWayBack() {
        let error = ErrorClassifier.classify(
            ConnectionError.notConnected,
            context: ErrorContext(operation: "switchDatabase")
        )

        #expect(error.category == .system)
        #expect(error.title == String(localized: "Not Connected"))
        #expect(error.recovery == String(localized: "Reconnect and try again."))
    }

    @Test("A jump host or username failure is an SSH failure by its case, with a way to fix it", arguments: [
        (
            SSHTunnelError.usernameMissing(host: "bastion.internal"),
            String(localized: "Edit the connection and enter the username under SSH Server or Jump Hosts.")
        ),
        (
            SSHTunnelError.jumpHostNeedsKey(host: "bastion.internal"),
            String(localized: "Edit the connection and set a key for this jump host under Jump Hosts.")
        ),
        (
            SSHTunnelError.jumpHostSharedKeyMissing(host: "bastion.internal"),
            String(localized: "Edit the connection and set a key for this jump host under Jump Hosts.")
        ),
        (
            SSHTunnelError.jumpHostFailed(host: "bastion.internal", reason: "Connection timed out"),
            String(localized: "Check this jump host's address, port, username and key under Jump Hosts.")
        ),
        (
            SSHTunnelError.jumpHostKeysUnreadable("Keychain retrieve failed: -25300"),
            String(localized: "Try again. If it keeps failing, update TablePro on this device.")
        )
    ])
    func jumpHostFailuresAreSSH(error: SSHTunnelError, recovery: String) {
        let classified = ErrorClassifier.classify(
            error,
            context: ErrorContext(operation: "connect", host: "db.internal", sshEnabled: true)
        )

        #expect(classified.category == .ssh)
        #expect(classified.title == String(localized: "SSH Tunnel Failed"))
        #expect(classified.message == error.localizedDescription)
        #expect(classified.recovery == recovery)
    }

    @Test("A jump host error names the host it is about")
    func jumpHostErrorsNameTheHost() {
        let errors: [SSHTunnelError] = [
            .usernameMissing(host: "bastion.internal"),
            .jumpHostNeedsKey(host: "bastion.internal"),
            .jumpHostSharedKeyMissing(host: "bastion.internal"),
            .jumpHostFailed(host: "bastion.internal", reason: "Connection timed out")
        ]

        for error in errors {
            #expect(error.localizedDescription.contains("bastion.internal"))
        }
    }
}
