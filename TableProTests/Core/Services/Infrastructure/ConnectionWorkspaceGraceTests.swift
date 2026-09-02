//
//  ConnectionWorkspaceGraceTests.swift
//  TableProTests
//
//  The timer that decides whether a connect ever announces itself, and the pane
//  the workspace resolves to on each side of it.
//
//  Measured on the SQLite sample: the connecting card was on screen for 39ms
//  and a "Not connected" pane was built for 38ms before it, so a window opened,
//  collapsed its chrome, built three pane hierarchies and put the chrome back,
//  all inside 103ms.
//

import Foundation
@testable import TablePro
import XCTest

@MainActor
final class ConnectionWorkspaceGraceTests: XCTestCase {
    private let connectionId = UUID()

    func testADiallingWorkspaceSaysNothingUntilItsConnectEarnsIt() {
        let workspace = makeWorkspace(phase: .connecting)

        XCTAssertEqual(workspace.resolvedPane, .preparing)
        XCTAssertFalse(
            ConnectionWindowPaneResolver.hidesChrome(for: workspace.resolvedPane),
            "the window that opens has to be the window that stays"
        )
    }

    func testAConnectThatOutlastsTheGraceGetsItsCard() async {
        let workspace = makeWorkspace(phase: .connecting)
        var revealCount = 0

        workspace.armConnectingProgressGrace { revealCount += 1 }
        try? await Task.sleep(for: LoadingRevealPolicy.grace + .milliseconds(250))

        XCTAssertTrue(workspace.hasOutlastedConnectGrace)
        XCTAssertEqual(workspace.resolvedPane, .connecting)
        XCTAssertEqual(revealCount, 1, "the reveal is what repaints a pane no phase change reaches")
    }

    /// A connect that lands first must leave no reveal behind, or the next one on the same
    /// workspace would show its card immediately.
    func testAConnectThatLandsFirstNeverReveals() async {
        let workspace = makeWorkspace(phase: .connecting)
        var revealCount = 0

        workspace.armConnectingProgressGrace { revealCount += 1 }
        workspace.cancelConnectingProgressGrace()
        try? await Task.sleep(for: LoadingRevealPolicy.grace + .milliseconds(250))

        XCTAssertFalse(workspace.hasOutlastedConnectGrace)
        XCTAssertEqual(revealCount, 0)
    }

    /// The phase churn of a reconnect must not keep pushing the reveal further out, or a
    /// connection that redials on a loop would never report anything at all.
    func testReArmingDoesNotRestartAWaitAlreadyRunning() async {
        let workspace = makeWorkspace(phase: .connecting)
        var revealCount = 0

        workspace.armConnectingProgressGrace { revealCount += 1 }
        try? await Task.sleep(for: .milliseconds(250))
        workspace.armConnectingProgressGrace { revealCount += 1 }
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(workspace.hasOutlastedConnectGrace, "the second arm must not have reset the clock")
        XCTAssertEqual(revealCount, 1)
    }

    /// `startActivationConnectIfNeeded` returns without dialling when the phase disallows it or the
    /// connection record has gone. Without the grace timing `.idle` out too, such a window would sit
    /// blank with no message and no Connect button.
    func testAWindowThatNeverDialsFallsBackToTheNotConnectedPane() async {
        let workspace = makeWorkspace(phase: .idle)

        XCTAssertEqual(workspace.resolvedPane, .preparing)

        workspace.armConnectingProgressGrace {}
        try? await Task.sleep(for: LoadingRevealPolicy.grace + .milliseconds(250))

        XCTAssertEqual(workspace.resolvedPane, .unavailable(.notConnected))
    }

    func testTearingDownAWorkspaceTakesItsPendingRevealWithIt() async {
        let workspace = makeWorkspace(phase: .connecting)
        var revealCount = 0

        workspace.armConnectingProgressGrace { revealCount += 1 }
        workspace.teardown()
        try? await Task.sleep(for: LoadingRevealPolicy.grace + .milliseconds(250))

        XCTAssertEqual(revealCount, 0)
    }

    private func makeWorkspace(phase: ConnectionWindowPhase) -> ConnectionWorkspace {
        ConnectionWorkspace(
            connectionId: connectionId,
            payload: nil,
            autoConnect: true,
            payloadConnection: DatabaseConnection(
                id: connectionId,
                name: "Chinook (Sample)",
                database: "/tmp/Chinook.sqlite",
                type: .sqlite
            ),
            session: nil,
            sessionState: nil,
            rightPanelState: nil,
            phase: phase
        )
    }
}
