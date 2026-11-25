//
//  SetupGuideGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// The macOS rows of the gate table in core/docs/decisions/0049-a-setup-guide-shows-on-an-empty-library.md.
struct SetupGuideGateRow: Sendable, CustomTestStringConvertible {
    let name: String
    let inputs: SetupGuideGate.Inputs
    let shows: Bool

    var testDescription: String { name }

    static func launch(
        _ name: String,
        shows: Bool,
        isUserSession: Bool = true,
        hasRoutedWork: Bool = false,
        isUITestSandbox: Bool = false,
        uiTestRequestsGuide: Bool = false,
        libraryReadable: Bool = true,
        connectionCount: Int = 0,
        hasSeen: Bool = false
    ) -> SetupGuideGateRow {
        SetupGuideGateRow(
            name: name,
            inputs: SetupGuideGate.Inputs(
                trigger: .launch,
                isUserSession: isUserSession,
                hasRoutedWork: hasRoutedWork,
                isUITestSandbox: isUITestSandbox,
                uiTestRequestsGuide: uiTestRequestsGuide,
                libraryReadable: libraryReadable,
                connectionCount: connectionCount,
                hasSeen: hasSeen
            ),
            shows: shows
        )
    }

    static let table: [SetupGuideGateRow] = [
        .launch("G1 an empty library read at launch, never seen", shows: true),
        .launch("G2 seen before", shows: false, hasSeen: true),
        .launch("G3 one connection, the sample counting as one", shows: false, connectionCount: 1),
        .launch("G4 a library that could not be read", shows: false, libraryReadable: false),
        // G5: groups are no input, so an empty library with groups is G1.
        .launch("G5 groups but no connection", shows: true),
        .launch("G7 a process an intent or MCP started", shows: false, isUserSession: false),
        .launch("G8 a routed request, import, share or launch intent", shows: false, hasRoutedWork: true),
        .launch("G9 the UI test sandbox without the variable", shows: false, isUITestSandbox: true),
        .launch("G10 the UI test sandbox with the variable", shows: true, isUITestSandbox: true, uiTestRequestsGuide: true),
        .launch(
            "G10 seen in the sandbox",
            shows: false,
            isUITestSandbox: true,
            uiTestRequestsGuide: true,
            hasSeen: true
        ),
    ]
}

struct SetupGuideGateTests {
    @Test("Each macOS row of the gate table", arguments: SetupGuideGateRow.table)
    func gateTable(_ row: SetupGuideGateRow) {
        #expect(SetupGuideGate.shouldPresent(row.inputs) == row.shows)
    }

    @Test("G6 the Help menu opens the guide whatever the launch rows say")
    func menuAlwaysShows() {
        for row in SetupGuideGateRow.table {
            var inputs = row.inputs
            inputs.trigger = .menu
            inputs.isUserSession = false
            inputs.hasRoutedWork = true
            inputs.connectionCount = 4
            inputs.hasSeen = true
            #expect(SetupGuideGate.shouldPresent(inputs), "\(row.name)")
        }
    }

    @Test("The guide's seen flag is its own key, local to this Mac")
    func seenFlag() throws {
        let suite = try EphemeralDefaults()
        let storage = AppSettingsStorage(userDefaults: suite.defaults)
        #expect(!storage.hasSeenSetupGuide())

        storage.markSetupGuideSeen()

        #expect(storage.hasSeenSetupGuide())
        #expect(suite.defaults.bool(forKey: "com.TablePro.settings.setupGuideSeen"))
    }

    @Test("An older build's welcome sheet flag still proves an earlier launch, and does not count as seen")
    func olderOnboardingFlag() throws {
        let suite = try EphemeralDefaults()
        suite.defaults.set(true, forKey: "com.TablePro.settings.hasCompletedOnboarding")
        let storage = AppSettingsStorage(userDefaults: suite.defaults)

        #expect(storage.hasLaunchedBefore())
        #expect(!storage.hasSeenSetupGuide())
    }
}
