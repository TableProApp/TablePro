import Foundation
@testable import TableProMobile
import Testing

@MainActor
struct ConnectedScreenTests {
    private let failure = AppError(
        category: .network,
        title: "Connection Lost",
        message: "The server closed the connection.",
        recovery: nil,
        underlying: nil
    )

    private func screen(
        _ phase: ConnectionCoordinator.ConnectionPhase,
        isReconnecting: Bool = false,
        isHeldByEditor: Bool = false
    ) -> ConnectedScreen {
        ConnectedScreen.resolve(phase: phase, isReconnecting: isReconnecting, isHeldByEditor: isHeldByEditor)
    }

    private func showsTabs(_ screen: ConnectedScreen) -> Bool {
        guard case .tabs = screen else { return false }
        return true
    }

    @Test("A connected session shows the tabs whether or not an editor holds them")
    func connectedShowsTabs() {
        #expect(showsTabs(screen(.connected)))
        #expect(showsTabs(screen(.connected, isHeldByEditor: true)))
        #expect(showsTabs(screen(.connected, isReconnecting: true)))
    }

    @Test("A failure with no unsaved edits shows the error")
    func failureShowsError() {
        let resolved = screen(.failed(failure))
        guard case .failed(let error) = resolved else {
            Issue.record("Expected the error screen, got \(resolved)")
            return
        }
        #expect(error.title == failure.title)
    }

    @Test("A lost session with no unsaved edits shows the lost screen, and its redial shows progress")
    func lostShowsLostThenProgress() {
        let resolved = screen(.lost(failure))
        guard case .lost(let error) = resolved else {
            Issue.record("Expected the lost screen, got \(resolved)")
            return
        }
        #expect(error.message == failure.message)

        let redialing = screen(.lost(failure), isReconnecting: true)
        guard case .connecting = redialing else {
            Issue.record("Expected the connecting screen, got \(redialing)")
            return
        }
    }

    @Test("A cancelled connect shows the neutral not-connected screen, not an error")
    func cancelledShowsNotConnected() {
        let resolved = screen(.notConnected)
        guard case .notConnected = resolved else {
            Issue.record("Expected the not-connected screen, got \(resolved)")
            return
        }
    }

    @Test("A failed or lost session under unsaved edits keeps the tabs and the editor on screen")
    func failureUnderEditsKeepsTabs() {
        #expect(showsTabs(screen(.failed(failure), isHeldByEditor: true)))
        #expect(showsTabs(screen(.lost(failure), isHeldByEditor: true)))
        #expect(showsTabs(screen(.connecting, isHeldByEditor: true)))
        #expect(showsTabs(screen(.notConnected, isHeldByEditor: true)))
    }

    @Test("Connecting with no unsaved edits shows the connecting screen")
    func connectingShowsProgress() {
        let resolved = screen(.connecting)
        guard case .connecting = resolved else {
            Issue.record("Expected the connecting screen, got \(resolved)")
            return
        }
    }
}
