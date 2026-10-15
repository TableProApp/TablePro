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

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class CompareSyncStartStateTests {
    private func endpoint(name: String, safeModeLevel: SafeModeLevel = .silent) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "app", schema: nil),
            connectionName: name,
            databaseType: .postgresql,
            safeModeLevel: safeModeLevel,
            color: .blue
        )
    }

    @Test
    func neitherEndpointIsPreselected() {
        let session = CompareSyncSession()

        #expect(session.source == nil)
        #expect(session.target == nil, "the side that gets written to is never chosen for the user")
    }

    @Test
    func bothPickersReadAsUnchosen() {
        #expect(DatabaseEndpointSide.source.placeholderTitle == "Choose Source")
        #expect(DatabaseEndpointSide.target.placeholderTitle == "Choose Target")
    }

    @Test
    func compareRefusesUntilBothEndpointsAreChosen() {
        let session = CompareSyncSession()
        #expect(!session.canCompare)
        #expect(session.compareDisabledReason == "Choose a source to compare from.")

        session.source = endpoint(name: "prod")

        #expect(!session.canCompare, "one endpoint is not a comparison")
        #expect(session.compareDisabledReason == "Choose a target to compare against.")

        session.target = endpoint(name: "staging")

        #expect(session.canCompare)
        #expect(session.compareDisabledReason == nil)
    }

    @Test
    func swapHasNothingToSwapUntilAnEndpointIsChosen() {
        let session = CompareSyncSession()
        #expect(!session.canSwap)

        session.target = endpoint(name: "staging")

        #expect(session.canSwap, "one endpoint is enough to move it to the other side")
    }

    @Test
    func theBannerStatesNothingHasBeenWrittenBeforeAnyRun() {
        #expect(CompareSyncSession().bannerText == "Comparing only. Nothing has been written.")
    }

    /// The window opens on Structure, so a comparison that has not run yet cannot offer a script.
    @Test
    func noScriptCanBeGeneratedBeforeAComparisonRuns() {
        let session = CompareSyncSession()

        #expect(!session.canBuildScript)
        #expect(session.scriptDisabledReason == "Compare the two databases first.")
    }
}
