//
//  WindowTabGroupingTests.swift
//  TableProTests
//
//  Tests for correct window tab grouping behavior:
//  - Same-connection tabs merge into the same window
//  - Different-connection tabs stay in separate windows
//  - WindowOpener tracks pending connectionId for AppDelegate
//

import Foundation
import Testing

@testable import TablePro

@Suite("WindowTabGrouping")
@MainActor
struct WindowTabGroupingTests {
    // MARK: - WindowOpener pending connectionId

    @Test("openNativeTab sets pendingConnectionId from payload")
    func openNativeTabSetsPendingConnectionId() {
        let connectionId = UUID()
        let opener = WindowOpener.shared

        // No openWindow action set, so it won't actually open — but pendingConnectionId should be set
        opener.openWindow = nil
        let payload = EditorTabPayload(connectionId: connectionId, tabType: .table, tableName: "users")
        opener.openNativeTab(payload)

        #expect(opener.pendingConnectionId == connectionId)
    }

    @Test("pendingConnectionId is nil initially")
    func pendingConnectionIdNilInitially() {
        let opener = WindowOpener.shared
        opener.pendingConnectionId = nil

        #expect(opener.pendingConnectionId == nil)
    }

    @Test("consumePendingConnectionId returns and clears the value")
    func consumePendingConnectionIdReturnsAndClears() {
        let connectionId = UUID()
        let opener = WindowOpener.shared
        opener.pendingConnectionId = connectionId

        let consumed = opener.consumePendingConnectionId()

        #expect(consumed == connectionId)
        #expect(opener.pendingConnectionId == nil)
    }

    @Test("consumePendingConnectionId returns nil when nothing pending")
    func consumePendingConnectionIdReturnsNilWhenEmpty() {
        let opener = WindowOpener.shared
        opener.pendingConnectionId = nil

        let consumed = opener.consumePendingConnectionId()

        #expect(consumed == nil)
    }

    // MARK: - TabbingIdentifier resolution

    @Test("tabbingIdentifier uses pending connectionId when available")
    func tabbingIdentifierUsesPendingConnectionId() {
        let connectionId = UUID()
        let expected = "com.TablePro.main.\(connectionId.uuidString)"

        let result = TabbingIdentifierResolver.resolve(pendingConnectionId: connectionId, existingIdentifier: nil)

        #expect(result == expected)
    }

    @Test("tabbingIdentifier falls back to existing window identifier when no pending")
    func tabbingIdentifierFallsBackToExistingWindow() {
        let existingId = "com.TablePro.main.AAAA-BBBB"

        let result = TabbingIdentifierResolver.resolve(pendingConnectionId: nil, existingIdentifier: existingId)

        #expect(result == existingId)
    }

    @Test("tabbingIdentifier uses generic default when no pending and no existing window")
    func tabbingIdentifierUsesGenericDefault() {
        let result = TabbingIdentifierResolver.resolve(pendingConnectionId: nil, existingIdentifier: nil)

        #expect(result == "com.TablePro.main")
    }

    @Test("tabbingIdentifier prefers pending connectionId over existing window")
    func tabbingIdentifierPrefersPendingOverExisting() {
        let connectionId = UUID()
        let expected = "com.TablePro.main.\(connectionId.uuidString)"
        let existingId = "com.TablePro.main.DIFFERENT"

        let result = TabbingIdentifierResolver.resolve(pendingConnectionId: connectionId, existingIdentifier: existingId)

        #expect(result == expected)
    }

    // MARK: - Multi-connection tab grouping scenarios

    @Test("Two connections produce different tabbingIdentifiers")
    func twoConnectionsProduceDifferentIdentifiers() {
        let connectionA = UUID()
        let connectionB = UUID()

        let idA = TabbingIdentifierResolver.resolve(pendingConnectionId: connectionA, existingIdentifier: nil)
        let idB = TabbingIdentifierResolver.resolve(pendingConnectionId: connectionB, existingIdentifier: nil)

        #expect(idA != idB)
        #expect(idA.contains(connectionA.uuidString))
        #expect(idB.contains(connectionB.uuidString))
    }

    @Test("Same connection produces same tabbingIdentifier")
    func sameConnectionProducesSameIdentifier() {
        let connectionId = UUID()

        let id1 = TabbingIdentifierResolver.resolve(pendingConnectionId: connectionId, existingIdentifier: nil)
        let id2 = TabbingIdentifierResolver.resolve(pendingConnectionId: connectionId, existingIdentifier: nil)

        #expect(id1 == id2)
    }

    @Test("Opening table tab for connection B while connection A window exists uses B's identifier")
    func openingTabForConnectionBUsesCorrectIdentifier() {
        let connectionA = UUID()
        let connectionB = UUID()
        let existingWindowIdentifier = "com.TablePro.main.\(connectionA.uuidString)"

        // When opening a tab for connection B, the pending connectionId should be B
        // This should produce B's identifier, NOT copy A's identifier
        let result = TabbingIdentifierResolver.resolve(
            pendingConnectionId: connectionB,
            existingIdentifier: existingWindowIdentifier
        )

        #expect(result == "com.TablePro.main.\(connectionB.uuidString)")
        #expect(result != existingWindowIdentifier)
    }

    // MARK: - groupAllConnections

    @Test("groupAllConnections returns shared identifier regardless of connectionId")
    func groupAllConnectionsReturnsSharedIdentifier() {
        let connectionA = UUID()
        let connectionB = UUID()

        let idA = TabbingIdentifierResolver.resolve(
            pendingConnectionId: connectionA, existingIdentifier: nil, groupAllConnections: true
        )
        let idB = TabbingIdentifierResolver.resolve(
            pendingConnectionId: connectionB, existingIdentifier: nil, groupAllConnections: true
        )

        #expect(idA == "com.TablePro.main")
        #expect(idB == "com.TablePro.main")
        #expect(idA == idB)
    }

    @Test("groupAllConnections ignores existingIdentifier")
    func groupAllConnectionsIgnoresExistingIdentifier() {
        let existing = "com.TablePro.main.SOME-UUID"

        let result = TabbingIdentifierResolver.resolve(
            pendingConnectionId: nil, existingIdentifier: existing, groupAllConnections: true
        )

        #expect(result == "com.TablePro.main")
    }
}
