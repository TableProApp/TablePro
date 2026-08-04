//
//  StructureRowProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("StructureRowProvider filter and sort")
struct StructureRowProviderTests {
    private func makeColumn(_ name: String) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: "text",
            isNullable: true,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
    }

    private func makeManager(columnNames: [String]) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.workingColumns = columnNames.map(makeColumn)
        return manager
    }

    private func makeProvider(
        columnNames: [String],
        filterText: String? = nil,
        sortDescriptor: StructureSortDescriptor? = nil
    ) -> StructureRowProvider {
        StructureRowProvider(
            changeManager: makeManager(columnNames: columnNames),
            tab: .columns,
            databaseType: .mysql,
            additionalFields: [.name, .type],
            filterText: filterText,
            sortDescriptor: sortDescriptor
        )
    }

    private func names(_ provider: StructureRowProvider) -> [String] {
        provider.rows.compactMap { $0.first ?? nil }
    }

    @Test("No filter shows every column with an identity source map")
    func noFilterShowsAll() {
        let provider = makeProvider(columnNames: ["id", "username", "email", "created"])
        #expect(provider.totalRowCount == 4)
        #expect(names(provider) == ["id", "username", "email", "created"])
        #expect(provider.filteredToSourceMap == [0, 1, 2, 3])
    }

    @Test("Filter matches the column name as a substring and maps back to the source index")
    func filterMatchesNameSubstring() {
        let provider = makeProvider(columnNames: ["id", "username", "email", "created"], filterText: "user")
        #expect(provider.totalRowCount == 1)
        #expect(names(provider) == ["username"])
        #expect(provider.filteredToSourceMap == [1])
    }

    @Test("Filter is case-insensitive")
    func filterIsCaseInsensitive() {
        let provider = makeProvider(columnNames: ["id", "username", "email", "created"], filterText: "EMAIL")
        #expect(names(provider) == ["email"])
        #expect(provider.filteredToSourceMap == [2])
    }

    @Test("A filter that matches nothing yields an empty display set")
    func filterMatchesNothing() {
        let provider = makeProvider(columnNames: ["id", "username", "email", "created"], filterText: "zzz")
        #expect(provider.totalRowCount == 0)
        #expect(provider.filteredToSourceMap.isEmpty)
    }

    @Test("Sorting reorders rows and keeps the source map aligned to display order")
    func sortReordersAndKeepsSourceMap() {
        let provider = makeProvider(
            columnNames: ["id", "username", "email", "created"],
            sortDescriptor: StructureSortDescriptor(column: 0, ascending: true)
        )
        #expect(names(provider) == ["created", "email", "id", "username"])
        #expect(provider.filteredToSourceMap == [3, 2, 0, 1])
    }

    @Test("Filter and sort compose: filter first, then order the survivors")
    func filterThenSort() {
        let provider = makeProvider(
            columnNames: ["alpha", "beta", "gamma", "alpine"],
            filterText: "al",
            sortDescriptor: StructureSortDescriptor(column: 0, ascending: true)
        )
        #expect(names(provider) == ["alpha", "alpine"])
        #expect(provider.filteredToSourceMap == [0, 3])
    }

    @Test("A display row maps to the source entity behind it")
    func sourceIndexFollowsDisplayOrder() {
        let provider = makeProvider(
            columnNames: ["alpha", "beta", "gamma", "alpine"],
            filterText: "al",
            sortDescriptor: StructureSortDescriptor(column: 0, ascending: false)
        )
        #expect(provider.sourceIndex(atDisplay: 0) == 3)
        #expect(provider.sourceIndex(atDisplay: 1) == 0)
        #expect(provider.sourceIndex(atDisplay: 2) == nil)
        #expect(provider.sourceIndex(atDisplay: -1) == nil)
    }
}

@MainActor @Suite("StructureRowProvider modified and deleted state")
struct StructureRowProviderChangeStateTests {
    private func loadedManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "users",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "email", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [IndexInfo(name: "idx_email", columns: ["email"], isUnique: false,
                                isPrimary: false, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    private func provider(
        _ manager: StructureChangeManager,
        tab: StructureTab = .columns,
        filterText: String? = nil
    ) -> StructureRowProvider {
        StructureRowProvider(
            changeManager: manager,
            tab: tab,
            databaseType: .mysql,
            additionalFields: [.primaryKey],
            filterText: filterText
        )
    }

    @Test("An untouched column reports no modified fields")
    func untouchedColumnHasNoModifiedFields() {
        let manager = loadedManager()
        #expect(provider(manager).modifiedFieldIndices(atDisplay: 0).isEmpty)
    }

    @Test("Only the edited field is reported, resolved through the display map")
    func editedFieldIsReportedThroughFilter() throws {
        let manager = loadedManager()
        var column = manager.workingColumns[1]
        column.dataType = "TEXT"
        manager.updateColumn(id: column.id, with: column)

        let filtered = provider(manager, filterText: "email")
        let typeIndex = try #require(filtered.orderedColumnFields.firstIndex(of: .type))
        #expect(filtered.modifiedFieldIndices(atDisplay: 0) == [typeIndex])
    }

    @Test("An index's edited field is reported")
    func editedIndexFieldIsReported() {
        let manager = loadedManager()
        var index = manager.workingIndexes[0]
        index.isUnique = true
        manager.updateIndex(id: index.id, with: index)

        #expect(provider(manager, tab: .indexes).modifiedFieldIndices(atDisplay: 0) == [3])
    }

    @Test("A column that does not exist on the server yet reports no modified fields")
    func newColumnReportsNoModifiedFields() {
        let manager = loadedManager()
        manager.addNewColumn()

        let sut = provider(manager)
        #expect(sut.modifiedFieldIndices(atDisplay: 2).isEmpty)
    }

    @Test("A column pending deletion is reported as deleted")
    func pendingDeleteIsReported() {
        let manager = loadedManager()
        manager.deleteColumn(id: manager.workingColumns[1].id)

        let sut = provider(manager)
        #expect(sut.isPendingDelete(atDisplay: 1))
        #expect(!sut.isPendingDelete(atDisplay: 0))
    }
}
