import TableProConnectionLibrary
import Testing

struct ConnectionStatusPresentationTests {
    @Test("Resting states carry no mark and no title", arguments: [
        ConnectionDisplayStatus.notConnected,
        ConnectionDisplayStatus.connected,
    ])
    func restingStatesAreQuiet(_ status: ConnectionDisplayStatus) {
        let presentation = ConnectionStatusPresentation(status)

        #expect(presentation.symbol == nil)
        #expect(presentation.title == nil)
        #expect(presentation.help == nil)
        #expect(!presentation.isBusy)
    }

    @Test("Connecting and reconnecting show progress and offer Cancel", arguments: [
        ConnectionDisplayStatus.connecting,
        ConnectionDisplayStatus.reconnecting(attempt: 2, of: 10),
    ])
    func busyStatesShowProgress(_ status: ConnectionDisplayStatus) {
        let presentation = ConnectionStatusPresentation(status)

        #expect(presentation.symbol == .progress)
        #expect(presentation.isBusy)
        #expect(presentation.primaryAction == .cancel)
        #expect(presentation.tint == .secondary)
    }

    @Test("Reconnecting names the attempt")
    func reconnectingNamesTheAttempt() {
        let presentation = ConnectionStatusPresentation(.reconnecting(attempt: 3, of: 10))

        #expect(presentation.title == "Reconnecting (3 of 10)")
        #expect(presentation.accessibilityStatus == "Reconnecting (3 of 10)")
    }

    @Test("A single redial reads Reconnecting without a count")
    func singleRedialHasNoCount() {
        #expect(ConnectionStatusPresentation(.reconnecting(attempt: 1, of: 1)).title == "Reconnecting")
    }

    @Test("A lost session and a failed connect draw different symbols")
    func lostAndFailedDiffer() {
        let lost = ConnectionStatusPresentation(.lost(cause: nil))
        let failed = ConnectionStatusPresentation(.failed(cause: nil))

        #expect(lost.symbol == .lost)
        #expect(failed.symbol == .failed)
        #expect(lost.symbol?.systemName == "bolt.slash.fill")
        #expect(failed.symbol?.systemName == "exclamationmark.triangle.fill")
        #expect(lost.tint == .warning)
        #expect(failed.tint == .critical)
        #expect(lost.primaryAction == .reconnect)
        #expect(failed.primaryAction == .connect)
    }

    @Test("The cause reaches the help text and the accessibility status")
    func causeIsNamed() {
        let presentation = ConnectionStatusPresentation(.lost(cause: "Server closed the connection."))

        #expect(presentation.cause == "Server closed the connection.")
        #expect(presentation.help == "Connection lost: Server closed the connection.")
        #expect(presentation.accessibilityStatus == presentation.help)
    }

    @Test("An empty cause reads as no cause")
    func emptyCauseIsDropped() {
        let presentation = ConnectionStatusPresentation(.failed(cause: ""))

        #expect(presentation.cause == nil)
        #expect(presentation.help == "Couldn't connect")
    }

    @Test("Disconnect is offered whenever a session still holds a driver", arguments: [
        (ConnectionDisplayStatus.connected, true),
        (ConnectionDisplayStatus.reconnecting(attempt: 1, of: 10), true),
        (ConnectionDisplayStatus.lost(cause: nil), true),
        (ConnectionDisplayStatus.connecting, false),
        (ConnectionDisplayStatus.failed(cause: nil), false),
        (ConnectionDisplayStatus.notConnected, false),
    ])
    func disconnectFollowsTheSession(_ status: ConnectionDisplayStatus, _ offered: Bool) {
        #expect(ConnectionStatusPresentation(status).offersDisconnect == offered)
    }
}
