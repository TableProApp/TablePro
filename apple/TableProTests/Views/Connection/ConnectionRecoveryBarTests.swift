//
//  ConnectionRecoveryBarTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

@MainActor
struct ConnectionRecoveryBarTests {
    @Test("The bar names the connection, the attempt and the cap")
    func barNamesTheAttempt() {
        let content = ConnectionRecoveryBarContent(
            connectionName: "Production",
            progress: ConnectionRecoveryProgress(attempt: 3, cause: "The SSH tunnel closed.")
        )

        #expect(content.title == "Reconnecting to Production (3 of 10)")
        #expect(content.cause == "The SSH tunnel closed.")
        #expect(content.accessibilityLabel == "Reconnecting to Production (3 of 10), The SSH tunnel closed.")
    }

    @Test("A reconnect with no named cause shows the attempt alone")
    func noCauseShowsTheAttemptAlone() {
        for cause in [nil, ""] as [String?] {
            let content = ConnectionRecoveryBarContent(
                connectionName: "Production",
                progress: ConnectionRecoveryProgress(attempt: 1, maxAttempts: 4, cause: cause)
            )
            #expect(content.title == "Reconnecting to Production (1 of 4)")
            #expect(content.cause == nil)
            #expect(content.accessibilityLabel == content.title)
        }
    }

    /// The pane drew a plug for a lost session while the rail drew the failed-connect triangle in
    /// red for the same state; both now take the presentation's shapes.
    @Test("The unavailable pane draws the presentation's shapes in outline")
    func paneSymbolsMatchThePresentation() throws {
        let info = ConnectionFailureInfo(message: "refused")
        let lost = try #require(ConnectionStatusPresentation(.lost(cause: nil)).symbol?.systemName)
        let failed = try #require(ConnectionStatusPresentation(.failed(cause: nil)).symbol?.systemName)

        #expect(ConnectionUnavailableView.symbolName(for: .disconnected(nil)) == "bolt.slash")
        #expect(ConnectionUnavailableView.symbolName(for: .failed(info)) == "exclamationmark.triangle")
        #expect(lost.hasPrefix("bolt.slash"))
        #expect(failed.hasPrefix("exclamationmark.triangle"))
        #expect(ConnectionUnavailableView.symbolName(for: .notConnected) == nil)
        #expect(ConnectionUnavailableView.symbolName(for: .cancelled) == nil)
    }
}
