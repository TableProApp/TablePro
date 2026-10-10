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

    @Test("A missing driver is a configuration problem and names the type")
    func driverNotFoundIsConfiguration() {
        let error = ErrorClassifier.classify(
            ConnectionError.driverNotFound("cassandra"),
            context: ErrorContext(operation: "connect")
        )

        #expect(error.category == .config)
        #expect(error.title == String(localized: "Driver Unavailable"))
        #expect(error.message.contains("cassandra"))
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
}
