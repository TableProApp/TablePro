//
//  WindowTabGroupingTests.swift
//  TableProTests
//
//  Tests for `WindowManager.tabbingIdentifier(for:)` — the static helper that
//  drives macOS native window tab grouping for main editor windows.
//
//  The earlier `WindowOpener.pendingPayloads` / `acknowledgePayload` /
//  `consumeOldestPendingConnectionId` queue was removed when
//  `WindowManager.openTab` started performing tab-group merge synchronously
//  at window-creation time. The corresponding tests have been removed.
//

import Foundation
import Testing

@testable import TablePro

@Suite("WindowTabGrouping")
@MainActor
struct WindowTabGroupingTests {
    init() {
        // Tests assume per-connection grouping; reset in case a prior suite changed it.
        AppSettingsManager.shared.tabs.groupAllConnectionTabs = false
    }

    @Test("tabbingIdentifier produces a connection-specific identifier")
    func tabbingIdentifierUsesConnectionId() {
        let connectionId = UUID()
        let expected = "com.TablePro.main.\(connectionId.uuidString)"

        let result = WindowManager.tabbingIdentifier(for: connectionId)

        #expect(result == expected)
    }

    @Test("Two connections produce different tabbingIdentifiers")
    func twoConnectionsProduceDifferentIdentifiers() {
        let connectionA = UUID()
        let connectionB = UUID()

        let idA = WindowManager.tabbingIdentifier(for: connectionA)
        let idB = WindowManager.tabbingIdentifier(for: connectionB)

        #expect(idA != idB)
        #expect(idA.contains(connectionA.uuidString))
        #expect(idB.contains(connectionB.uuidString))
    }

    @Test("Same connection produces same tabbingIdentifier")
    func sameConnectionProducesSameIdentifier() {
        let connectionId = UUID()

        let id1 = WindowManager.tabbingIdentifier(for: connectionId)
        let id2 = WindowManager.tabbingIdentifier(for: connectionId)

        #expect(id1 == id2)
    }
}
