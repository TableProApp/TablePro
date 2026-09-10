import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// `AppEvents.connectionStageChanged` is a `PassthroughSubject`, so it replays nothing: an
/// observer built after a step was sent could only ever report the generic fallback. That is what
/// a connection dialling through an SSH jump host used to do, announcing "Opening the connection"
/// for the whole of the tunnel handshake, because the surface that owns the observer was itself
/// held back for the first half second of every connect.
@Suite("Connection stage observer", .serialized)
@MainActor
struct ConnectionStageObserverTests {
    @Test("A step reported before the observer existed is still what it reports")
    func observerSeedsFromTheAttemptAlreadyRunning() {
        let connectionId = UUID()
        defer { DatabaseManager.shared.clearConnectionStage(for: connectionId) }

        let attempt = DatabaseManager.shared.connectionAttempts.begin(for: connectionId)
        DatabaseManager.shared.reportStage(.resolvingTunnel, attempt: attempt, for: connectionId)

        let observer = ConnectionStageObserver(connectionId: connectionId)

        #expect(observer.stage == .resolvingTunnel)
    }

    @Test("A connection with nothing in flight seeds nothing")
    func observerSeedsNothingWithoutAnAttempt() {
        let observer = ConnectionStageObserver(connectionId: UUID())

        #expect(observer.stage == nil)
    }

    /// A driver blocked in a C call outlives the attempt that started it and reports its steps
    /// late. Recording one over a newer attempt's is what a window joining that newer attempt
    /// would then seed itself from.
    @Test("A superseded attempt cannot report a step over the one that replaced it")
    func supersededAttemptIsRefused() {
        let connectionId = UUID()
        defer { DatabaseManager.shared.clearConnectionStage(for: connectionId) }

        let superseded = DatabaseManager.shared.connectionAttempts.begin(for: connectionId)
        let current = DatabaseManager.shared.connectionAttempts.begin(for: connectionId)
        DatabaseManager.shared.reportStage(.openingConnection, attempt: current, for: connectionId)

        DatabaseManager.shared.reportStage(.resolvingTunnel, attempt: superseded, for: connectionId)

        #expect(DatabaseManager.shared.currentStage(for: connectionId) == .openingConnection)
    }

    /// A settled connect has no step. Leaving the last one behind would seed the next window that
    /// opens on this connection with a stage from a connect that finished.
    @Test("Clearing the attempt takes its step with it")
    func settlingClearsTheRecord() {
        let connectionId = UUID()
        defer { DatabaseManager.shared.clearConnectionStage(for: connectionId) }

        let attempt = DatabaseManager.shared.connectionAttempts.begin(for: connectionId)
        DatabaseManager.shared.reportStage(.preparingSession, attempt: attempt, for: connectionId)
        #expect(DatabaseManager.shared.currentStage(for: connectionId) == .preparingSession)

        DatabaseManager.shared.clearConnectionStage(for: connectionId)

        #expect(ConnectionStageObserver(connectionId: connectionId).stage == nil)
    }

    @Test("An observer with no connection behind it reports nothing and subscribes to nothing")
    func observerWithoutAConnectionIsInert() {
        #expect(ConnectionStageObserver(connectionId: nil).stage == nil)
    }
}
