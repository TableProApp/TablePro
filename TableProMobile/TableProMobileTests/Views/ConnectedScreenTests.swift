import Foundation
@testable import TableProMobile
import Testing

@MainActor
@Suite("Connected screen")
struct ConnectedScreenTests {
    private let failure = AppError(
        category: .network,
        title: "Connection Lost",
        message: "The server closed the connection.",
        recovery: nil,
        underlying: nil
    )

    private func showsTabs(_ screen: ConnectedScreen) -> Bool {
        guard case .tabs = screen else { return false }
        return true
    }

    @Test("A connected session shows the tabs whether or not an editor holds them")
    func connectedShowsTabs() {
        #expect(showsTabs(ConnectedScreen.resolve(phase: .connected, isHeldByEditor: false)))
        #expect(showsTabs(ConnectedScreen.resolve(phase: .connected, isHeldByEditor: true)))
    }

    @Test("A failure with no unsaved edits shows the error")
    func failureShowsError() {
        let screen = ConnectedScreen.resolve(phase: .error(failure), isHeldByEditor: false)
        guard case .failed(let error) = screen else {
            Issue.record("Expected the error screen, got \(screen)")
            return
        }
        #expect(error.title == failure.title)
    }

    @Test("A failed reconnect under unsaved edits keeps the tabs and the editor on screen")
    func failureUnderEditsKeepsTabs() {
        #expect(showsTabs(ConnectedScreen.resolve(phase: .error(failure), isHeldByEditor: true)))
        #expect(showsTabs(ConnectedScreen.resolve(phase: .connecting, isHeldByEditor: true)))
    }

    @Test("Connecting with no unsaved edits shows the connecting screen")
    func connectingShowsProgress() {
        let screen = ConnectedScreen.resolve(phase: .connecting, isHeldByEditor: false)
        guard case .connecting = screen else {
            Issue.record("Expected the connecting screen, got \(screen)")
            return
        }
    }
}
