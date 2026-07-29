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
}
