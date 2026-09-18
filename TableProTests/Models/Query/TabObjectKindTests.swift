//
//  TabObjectKindTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

/// A tab used to carry one `isView` Bool, derived from `allowsRowEditing`, which is deliberately true
/// for a materialized view because a matview does hold rows. So a matview reached the Structure tab as
/// a table and was offered column, index and constraint edits PostgreSQL always refuses. The kind now
/// travels beside the Bool rather than replacing it: they answer different questions. (#2726)
@Suite("Tab Object Kind")
@MainActor
struct TabObjectKindTests {
    private func tableTab() -> QueryTab {
        QueryTab(id: UUID(), title: "mv_sales", query: "SELECT 1", tabType: .table, tableName: "mv_sales")
    }

    @Test("A materialized view keeps its kind and leaves row editing alone")
    func materializedViewKeepsItsKind() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(
            tableName: "mv_sales",
            databaseType: .postgresql,
            databaseName: "shop",
            isView: false,
            objectType: .materializedView
        )

        let tab = try #require(manager.selectedTab)
        #expect(tab.tableContext.objectType == .materializedView)
        #expect(tab.tableContext.isView == false)
        #expect(tab.tableContext.resolvedObjectKind() == .materializedView)
    }

    @Test("Retargeting a tab writes the new object's kind over the old one")
    func retargetReplacesTheKind() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(
            tableName: "orders", databaseType: .postgresql, databaseName: "shop", objectType: .table
        )
        try manager.replaceTabContent(
            tableName: "v_orders",
            databaseType: .postgresql,
            isView: true,
            objectType: .view,
            databaseName: "shop"
        )

        let tab = try #require(manager.selectedTab)
        #expect(tab.tableContext.objectType == .view)
        #expect(tab.tableContext.resolvedObjectKind() == .view)
    }

    // MARK: - Persistence

    @Test("The kind round-trips through the persisted tab")
    func kindRoundTrips() {
        var tab = tableTab()
        tab.tableContext.objectType = .materializedView

        let persisted = tab.toPersistedTab()
        #expect(persisted.objectTypeRawValue == "MATERIALIZED VIEW")
        #expect(QueryTab(from: persisted, defaultPageSize: 1_000).tableContext.objectType == .materializedView)
    }

    /// A tab saved before this shipped has no key at all. It must still decode, and it must fall back
    /// to what the Bool beside it can still say, because the alternative is a thrown error that takes
    /// every tab in the aggregate with it.
    ///
    /// The JSON is built by dropping the key from a real encode rather than typed out by hand, so the
    /// test cannot pass or fail on a spelling the encoder does not use: `TabType` has no raw value, so
    /// it encodes as `{"table": {}}` rather than `"table"`.
    @Test("A file written before the kind existed decodes, and falls back to the Bool")
    func missingKeyDecodesToTheFallback() throws {
        let persisted = try decodePersisted(droppingKindFrom: tableTab())
        #expect(persisted.objectTypeRawValue == nil)

        let restored = QueryTab(from: persisted, defaultPageSize: 1_000)
        #expect(restored.tableContext.objectType == nil)
        #expect(restored.tableContext.resolvedObjectKind() == .table)
    }

    @Test("A view saved before the kind existed falls back to a view, not a table")
    func missingKeyOnAViewFallsBackToView() throws {
        var tab = tableTab()
        tab.tableContext.isView = true
        tab.tableContext.objectType = .view

        let persisted = try decodePersisted(droppingKindFrom: tab)
        #expect(persisted.objectTypeRawValue == nil)
        #expect(QueryTab(from: persisted, defaultPageSize: 1_000).tableContext.resolvedObjectKind() == .view)
    }

    /// A raw String rather than the enum, so a spelling a newer build invents is dropped instead of
    /// throwing. A tab that comes back gated as a table is a smaller failure than a session that does
    /// not come back.
    @Test("A kind this build does not know decodes to nil rather than throwing")
    func unknownKindDecodesToNil() throws {
        var tab = tableTab()
        tab.tableContext.objectType = .materializedView

        var object = try jsonObject(of: tab.toPersistedTab())
        object["objectTypeRawValue"] = "GRAPH"
        let persisted = try JSONDecoder().decode(
            PersistedTab.self, from: try JSONSerialization.data(withJSONObject: object)
        )

        #expect(persisted.objectTypeRawValue == "GRAPH")
        #expect(QueryTab(from: persisted, defaultPageSize: 1_000).tableContext.objectType == nil)
    }

    private func jsonObject(of persisted: PersistedTab) throws -> [String: Any] {
        let data = try JSONEncoder().encode(persisted)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodePersisted(droppingKindFrom tab: QueryTab) throws -> PersistedTab {
        var object = try jsonObject(of: tab.toPersistedTab())
        object.removeValue(forKey: "objectTypeRawValue")
        return try JSONDecoder().decode(
            PersistedTab.self, from: try JSONSerialization.data(withJSONObject: object)
        )
    }

    // MARK: - Window payload

    @Test("The kind survives a trip through a window-tab payload")
    func payloadCarriesTheKind() throws {
        var tab = tableTab()
        tab.tableContext.objectType = .foreignTable

        let payload = EditorTabPayload(from: tab, connectionId: UUID())
        #expect(payload.objectType == .foreignTable)

        let decoded = try JSONDecoder().decode(
            EditorTabPayload.self, from: try JSONEncoder().encode(payload)
        )
        #expect(decoded.objectType == .foreignTable)
    }

    @Test("A payload with no kind key decodes to nil")
    func payloadWithoutTheKindDecodes() throws {
        var tab = tableTab()
        tab.tableContext.objectType = .materializedView

        let data = try JSONEncoder().encode(EditorTabPayload(from: tab, connectionId: UUID()))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "objectType")

        let payload = try JSONDecoder().decode(
            EditorTabPayload.self, from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(payload.objectType == nil)
    }
}
