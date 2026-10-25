//
//  DataTabColumnLayoutStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class IsolatedLayoutPersister {
    let directory: URL
    let persister: FileColumnLayoutPersister

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        persister = FileColumnLayoutPersister(storageDirectory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

// The data tab's grid store: what layout a tab's grid reads, and when a table's layout is written.
@MainActor
struct DataTabColumnLayoutStoreTests {
    private let fixture = CoordinatorFixture()
    private let storage = IsolatedLayoutPersister()

    private static func rows(_ columns: [String]) -> TableRows {
        TableRows.from(
            queryRows: [columns.map { PluginCellValue.text("\($0) value") }],
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: "TEXT"), count: columns.count)
        )
    }

    private static func layout(
        widths: [String: CGFloat] = [:],
        order: [String]? = nil,
        hidden: Set<String> = []
    ) -> ColumnLayoutState {
        var layout = ColumnLayoutState()
        layout.columnWidths = widths
        layout.columnOrder = order
        layout.hiddenColumns = hidden
        return layout
    }

    private func makeStore(
        for tab: QueryTab,
        rows: TableRows,
        layout: ColumnLayoutState = ColumnLayoutState()
    ) -> QueryTabGridStateStore {
        var tab = tab
        tab.columnLayout = layout
        fixture.addTab(tab, rows: rows)
        return QueryTabGridStateStore(tabId: tab.id, coordinator: fixture.coordinator, persister: storage.persister)
    }

    private func tableTab(_ name: String? = "users") -> QueryTab {
        QueryTab(title: name ?? "table", query: "SELECT * FROM \(name ?? "t")", tabType: .table, tableName: name)
    }

    private func queryTab() -> QueryTab {
        QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
    }

    private func savedTab(_ id: UUID) -> QueryTab? {
        fixture.tabManager.tabs.first { $0.id == id }
    }

    // MARK: - What a tab reads

    @Test("A table tab reads its geometry from the saved table layout over the tab's own")
    func tableTabPrefersTheSavedLayout() throws {
        let tab = tableTab()
        let key = try #require(fixture.coordinator.columnLayoutTableKey(for: tab))
        storage.persister.save(Self.layout(widths: ["id": 60]), for: key)

        let store = makeStore(
            for: tab,
            rows: Self.rows(["id", "name"]),
            layout: Self.layout(widths: ["other": 999], hidden: ["name"])
        )

        #expect(store.layoutScope == .table(key))
        #expect(store.columnLayout.columnWidths == ["id": 60])
        #expect(store.columnLayout.hiddenColumns == ["name"])
    }

    @Test("A table tab with nothing saved reads the tab's own layout")
    func tableTabFallsBackToTheTab() {
        let store = makeStore(for: tableTab(), rows: Self.rows(["id"]), layout: Self.layout(widths: ["id": 60]))

        #expect(store.columnLayout.columnWidths == ["id": 60])
    }

    @Test("A table tab with no table name keeps its layout on the tab")
    func tableTabWithoutATableIsEphemeral() throws {
        let saved = tableTab()
        let key = try #require(fixture.coordinator.columnLayoutTableKey(for: saved))
        storage.persister.save(Self.layout(widths: ["id": 60]), for: key)

        let store = makeStore(for: tableTab(nil), rows: Self.rows(["id"]), layout: Self.layout(widths: ["fallback": 42]))

        #expect(store.layoutScope == .ephemeral)
        #expect(store.columnLayout.columnWidths == ["fallback": 42])
    }

    @Test("A query tab drops a saved order its columns no longer match and keeps the widths")
    func queryTabDropsAStaleOrder() {
        let store = makeStore(
            for: queryTab(),
            rows: Self.rows(["id", "business_model", "region"]),
            layout: Self.layout(widths: ["id": 60, "business_model": 120], order: ["id", "business_model"])
        )

        #expect(store.layoutScope == .ephemeral)
        #expect(store.columnLayout.columnOrder == nil)
        #expect(store.columnLayout.columnWidths == ["id": 60, "business_model": 120])
    }

    @Test("A query tab keeps an order saved for the same columns")
    func queryTabKeepsAMatchingOrder() {
        let store = makeStore(
            for: queryTab(),
            rows: Self.rows(["id", "business_model"]),
            layout: Self.layout(order: ["business_model", "id"])
        )

        #expect(store.columnLayout.columnOrder == ["business_model", "id"])
    }

    @Test("A query tab drops an order when two columns share a name")
    func queryTabDropsAnOrderOverDuplicateNames() {
        let store = makeStore(
            for: queryTab(),
            rows: Self.rows(["id", "id"]),
            layout: Self.layout(widths: ["id": 60], order: ["id", "id"])
        )

        #expect(store.columnLayout.columnOrder == nil)
        #expect(store.columnLayout.columnWidths == ["id": 60])
    }

    @Test("A query tab's dropped order stays on the tab for when its columns come back")
    func droppedOrderStaysOnTheTab() {
        let tab = queryTab()
        let store = makeStore(
            for: tab,
            rows: Self.rows(["id", "region"]),
            layout: Self.layout(order: ["id", "business_model"])
        )

        var layout = store.columnLayout
        layout.columnWidths = ["id": 80]
        store.columnLayout = layout

        #expect(savedTab(tab.id)?.columnLayout.columnWidths == ["id": 80])
        #expect(savedTab(tab.id)?.columnLayout.columnOrder == ["id", "business_model"])
    }

    // MARK: - When a table's layout is written

    @Test("A table tab's layout reaches the saved table layout only once the write is flushed")
    func writeWaitsForTheFlush() throws {
        let tab = tableTab()
        let key = try #require(fixture.coordinator.columnLayoutTableKey(for: tab))
        let store = makeStore(for: tab, rows: Self.rows(["name"]))

        store.columnLayout = Self.layout(widths: ["name": 180])

        #expect(storage.persister.load(for: key) == nil)
        #expect(store.columnLayout.columnWidths == ["name": 180])
        #expect(savedTab(tab.id)?.columnLayout.columnWidths == ["name": 180])

        store.flushPendingLayout()

        #expect(storage.persister.load(for: key)?.columnWidths == ["name": 180])
    }

    @Test("Discarding a pending write persists nothing")
    func discardDropsThePendingWrite() throws {
        let tab = tableTab()
        let key = try #require(fixture.coordinator.columnLayoutTableKey(for: tab))
        let store = makeStore(for: tab, rows: Self.rows(["name"]))
        store.columnLayout = Self.layout(widths: ["name": 180])

        store.discardPendingLayout()
        store.flushPendingLayout()

        #expect(storage.persister.load(for: key) == nil)
    }

    @Test("A reset clears the saved geometry and drops a pending write")
    func resetClearsTheSavedGeometry() throws {
        let tab = tableTab()
        let key = try #require(fixture.coordinator.columnLayoutTableKey(for: tab))
        storage.persister.save(Self.layout(widths: ["name": 120]), for: key)
        let store = makeStore(for: tab, rows: Self.rows(["name"]))
        store.columnLayout = Self.layout(widths: ["name": 180])

        var reset = store.columnLayout
        reset.resetGeometry()
        store.columnLayout = reset
        store.flushPendingLayout()

        #expect(storage.persister.load(for: key) == nil)
    }

    @Test("A pending write lands on the table it was made for after the tab moves on")
    func pendingWriteKeepsItsTable() throws {
        let tab = tableTab("users")
        let usersKey = try #require(fixture.coordinator.columnLayoutTableKey(for: tab))
        let store = makeStore(for: tab, rows: Self.rows(["name"]))
        store.columnLayout = Self.layout(widths: ["name": 180])

        _ = fixture.tabManager.mutate(tabId: tab.id) { $0.tableContext.tableName = "projects" }
        let moved = try #require(savedTab(tab.id))
        let projectsKey = try #require(fixture.coordinator.columnLayoutTableKey(for: moved))
        store.flushPendingLayout()

        #expect(storage.persister.load(for: usersKey)?.columnWidths == ["name": 180])
        #expect(storage.persister.load(for: projectsKey) == nil)
    }
}
