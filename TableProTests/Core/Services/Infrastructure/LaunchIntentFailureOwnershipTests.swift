//
//  LaunchIntentFailureOwnershipTests.swift
//  TableProTests
//
//  Opening a database file or URL builds its connection inside the router, so the launch intent
//  names no connection. A connect that failed there was then alerted over the window that already
//  showed the same failure, covering the button that fixed it.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Launch intent failure ownership")
@MainActor
struct LaunchIntentFailureOwnershipTests {
    private static let underlying = PluginError.pluginDisabled(pluginId: "com.TablePro.SQLiteDriver", pluginName: "SQLite")

    @Test("A file open whose connect failed in its window names that window's connection")
    func fileOpenFailureNamesItsConnection() {
        let connectionId = UUID()
        let error = TabRouterError.connectFailedInWindow(connectionId: connectionId, underlying: Self.underlying)
        let intent = LaunchIntent.openDatabaseFile(URL(fileURLWithPath: "/tmp/empty.sqlite"), .sqlite)

        #expect(LaunchIntentRouter.failedConnectionId(for: intent, error: error) == connectionId)
    }

    @Test("A file open that failed before any window opened names no connection")
    func preWindowFailureNamesNone() {
        let url = URL(fileURLWithPath: "/tmp/gone.sqlite")
        let intent = LaunchIntent.openDatabaseFile(url, .sqlite)

        #expect(LaunchIntentRouter.failedConnectionId(for: intent, error: TabRouterError.fileNoLongerExists(url)) == nil)
    }

    @Test("An intent that names its connection keeps naming it")
    func connectionIntentNamesItsConnection() {
        let connectionId = UUID()

        #expect(LaunchIntentRouter.failedConnectionId(for: .openConnection(connectionId), error: Self.underlying) == connectionId)
    }

    @Test("A failure handed to a window still reads as the driver's own message")
    func windowFailureKeepsTheUnderlyingMessage() {
        let error = TabRouterError.connectFailedInWindow(connectionId: UUID(), underlying: Self.underlying)

        #expect(error.localizedDescription == Self.underlying.localizedDescription)
    }
}
