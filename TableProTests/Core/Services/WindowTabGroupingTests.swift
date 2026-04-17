//
//  WindowTabGroupingTests.swift
//  TableProTests
//
//  Tests for correct window tab grouping behavior:
//  - Same-connection tabs merge into the same window
//  - Different-connection tabs stay in separate windows
//  - WindowOpener tracks pending payloads for tab-group attachment
//

import Foundation
import Testing

@testable import TablePro

@Suite("WindowTabGrouping")
@MainActor
struct WindowTabGroupingTests {
    // MARK: - WindowOpener pending payload tracking

    @Test("openNativeTab without openWindow falls back to notification and keeps pending")
    func openNativeTabWithoutOpenWindowFallsBack() {
        let connectionId = UUID()
        let opener = WindowOpener.shared

        opener.openWindow = nil
        let payload = EditorTabPayload(connectionId: connectionId, tabType: .table, tableName: "users")
        WindowManager.shared.openTab(payload: payload)

        // Payload stays pending (notification handler will create the window)
        #expect(opener.pendingPayloads.contains { $0.id == payload.id })
        // Clean up
        opener.acknowledgePayload(payload.id)
    }

    @Test("pendingPayloads is empty initially")
    func pendingPayloadsEmptyInitially() {
        let opener = WindowOpener.shared
        for entry in opener.pendingPayloads {
            opener.acknowledgePayload(entry.id)
        }

        #expect(opener.pendingPayloads.isEmpty)
    }

    @Test("acknowledgePayload removes the id from pending")
    func acknowledgePayloadRemovesId() {
        let opener = WindowOpener.shared
        let payloadId = UUID()

        opener.acknowledgePayload(payloadId)
        #expect(!opener.pendingPayloads.contains { $0.id == payloadId })
    }

    @Test("consumeOldestPendingConnectionId returns in FIFO order")
    func consumeOldestReturnsFIFO() {
        let opener = WindowOpener.shared
        // Clear any stale state
        while opener.consumeOldestPendingConnectionId() != nil {}

        let idA = UUID()
        let idB = UUID()
        let payloadA = EditorTabPayload(connectionId: idA, tabType: .query)
        let payloadB = EditorTabPayload(connectionId: idB, tabType: .query)

        opener.openWindow = nil
        WindowManager.shared.openTab(payload: payloadA)
        WindowManager.shared.openTab(payload: payloadB)

        let first = opener.consumeOldestPendingConnectionId()
        let second = opener.consumeOldestPendingConnectionId()

        #expect(first == idA)
        #expect(second == idB)
        #expect(opener.consumeOldestPendingConnectionId() == nil)
    }

    // MARK: - TabbingIdentifier resolution

    @Test("tabbingIdentifier produces connection-specific identifier")
    func tabbingIdentifierUsesConnectionId() {
        let connectionId = UUID()
        let expected = "com.TablePro.main.\(connectionId.uuidString)"

        let result = WindowOpener.tabbingIdentifier(for: connectionId)

        #expect(result == expected)
    }

    // MARK: - Multi-connection tab grouping scenarios

    @Test("Two connections produce different tabbingIdentifiers")
    func twoConnectionsProduceDifferentIdentifiers() {
        let connectionA = UUID()
        let connectionB = UUID()

        let idA = WindowOpener.tabbingIdentifier(for: connectionA)
        let idB = WindowOpener.tabbingIdentifier(for: connectionB)

        #expect(idA != idB)
        #expect(idA.contains(connectionA.uuidString))
        #expect(idB.contains(connectionB.uuidString))
    }

    @Test("Same connection produces same tabbingIdentifier")
    func sameConnectionProducesSameIdentifier() {
        let connectionId = UUID()

        let id1 = WindowOpener.tabbingIdentifier(for: connectionId)
        let id2 = WindowOpener.tabbingIdentifier(for: connectionId)

        #expect(id1 == id2)
    }
}
