//
//  ERDiagramViewModelForeignKeyTests.swift
//  TableProTests
//

import CoreGraphics
import Foundation
@testable import TablePro
import Testing

@MainActor
struct ERDiagramViewModelForeignKeyTests {
    private func loadedFixture() async -> ERDiagramLoadFixture {
        let fixture = ERDiagramLoadFixture(tableCount: 1, columnsPerTable: 3)
        fixture.driver.addTable("accounts", columns: [
            TestFixtures.makeColumnInfo(name: "tenant_id", isPrimaryKey: true),
            TestFixtures.makeColumnInfo(name: "id", isPrimaryKey: true),
            TestFixtures.makeColumnInfo(name: "name", dataType: "TEXT", isPrimaryKey: false)
        ])
        await fixture.viewModel.loadDiagram()
        return fixture
    }

    private func draft(of viewModel: ERDiagramViewModel) -> ERDiagramForeignKeyDraft? {
        guard case .addForeignKey(let draft) = viewModel.editSheet else { return nil }
        return draft
    }

    @Test("A drop on a member of a two-column key offers both key columns, the dragged pair in its place")
    func dropOnACompositeKeyOffersBothColumns() async throws {
        let fixture = await loadedFixture()
        defer { fixture.tearDown() }
        let target = ERDiagramColumnHit(
            nodeId: UUID(), tableName: "accounts", columnName: "id", rowRect: .zero, isDropped: false
        )

        fixture.viewModel.beginForeignKey(from: "table_0", column: "column_1", to: target)

        let started = try #require(draft(of: fixture.viewModel))
        #expect(started.referencedTable == "accounts")
        #expect(started.pairs.map { $0.referencedColumn } == ["tenant_id", "id"])
        #expect(started.pairs.last?.column == "column_1")
        #expect(started.foreignKey.referencedColumns == ["tenant_id", "id"])
    }

    @Test("Add Foreign Key from a column prefills the referenced table's whole primary key")
    func menuPrefillsTheWholeKey() async throws {
        let fixture = await loadedFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.beginForeignKey(from: "table_0", column: "column_2", to: nil)

        let started = try #require(draft(of: fixture.viewModel))
        #expect(started.referencedTable == "accounts")
        #expect(fixture.viewModel.referencedKeyColumns(in: "accounts") == ["tenant_id", "id"])
        #expect(started.pairs.map { $0.referencedColumn } == ["tenant_id", "id"])
        #expect(started.pairs.contains { $0.column == "column_2" })
    }

    @Test("A table with a single-column key still starts with one pair")
    func singleKeyIsOnePair() async throws {
        let fixture = await loadedFixture()
        defer { fixture.tearDown() }
        let target = ERDiagramColumnHit(
            nodeId: UUID(), tableName: "table_0", columnName: "column_0", rowRect: .zero, isDropped: false
        )

        fixture.viewModel.beginForeignKey(from: "accounts", column: "name", to: target)

        let started = try #require(draft(of: fixture.viewModel))
        #expect(started.pairs.map { $0.column } == ["name"])
        #expect(started.pairs.map { $0.referencedColumn } == ["column_0"])
    }
}
