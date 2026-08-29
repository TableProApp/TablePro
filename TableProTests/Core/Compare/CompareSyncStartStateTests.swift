//
//  CompareSyncStartStateTests.swift
//  TableProTests
//
//  What the Compare & Sync window promises before anything has been chosen: nothing is
//  preselected, nothing can run, and the strip says nothing has been written.
//
//  This was asserted through XCUITest against a window that never opens without a license, so it
//  ran nowhere. The window is a license-gated Pro feature and the UI test sandbox carries no
//  license, which is why the contract is checked here instead.
//

@testable import TablePro
import TableProPluginKit
import XCTest

@MainActor
final class CompareSyncStartStateTests: XCTestCase {
    private func endpoint(name: String, safeModeLevel: SafeModeLevel = .silent) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "app", schema: nil),
            connectionName: name,
            databaseType: .postgresql,
            safeModeLevel: safeModeLevel,
            color: .blue
        )
    }

    func testNeitherEndpointIsPreselected() {
        let session = CompareSyncSession()

        XCTAssertNil(session.source)
        XCTAssertNil(session.target, "the side that gets written to is never chosen for the user")
    }

    func testBothPickersReadAsUnchosen() {
        XCTAssertEqual(DatabaseEndpointSide.source.placeholderTitle, "Choose Source")
        XCTAssertEqual(DatabaseEndpointSide.target.placeholderTitle, "Choose Target")
    }

    func testCompareRefusesUntilBothEndpointsAreChosen() {
        let session = CompareSyncSession()
        XCTAssertFalse(session.canCompare)
        XCTAssertEqual(session.compareDisabledReason, "Choose a source to compare from.")

        session.source = endpoint(name: "prod")

        XCTAssertFalse(session.canCompare, "one endpoint is not a comparison")
        XCTAssertEqual(session.compareDisabledReason, "Choose a target to compare against.")

        session.target = endpoint(name: "staging")

        XCTAssertTrue(session.canCompare)
        XCTAssertNil(session.compareDisabledReason)
    }

    func testSwapHasNothingToSwapUntilAnEndpointIsChosen() {
        let session = CompareSyncSession()
        XCTAssertFalse(session.canSwap)

        session.target = endpoint(name: "staging")

        XCTAssertTrue(session.canSwap, "one endpoint is enough to move it to the other side")
    }

    func testTheBannerStatesNothingHasBeenWrittenBeforeAnyRun() {
        XCTAssertEqual(CompareSyncSession().bannerText, "Comparing only. Nothing has been written.")
    }

    /// The window opens on Structure, so a comparison that has not run yet cannot offer a script.
    func testNoScriptCanBeGeneratedBeforeAComparisonRuns() {
        let session = CompareSyncSession()

        XCTAssertFalse(session.canBuildScript)
        XCTAssertEqual(session.scriptDisabledReason, "Compare the two databases first.")
    }
}
