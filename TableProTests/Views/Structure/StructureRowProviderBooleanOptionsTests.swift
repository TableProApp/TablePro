//
//  StructureRowProviderBooleanOptionsTests.swift
//  TableProTests
//
//  The dropdown that edits a structure flag must offer the same tokens the grid
//  draws, and must never offer Set NULL: a flag is a schema property with no
//  NULL state, unlike a data cell.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("StructureRowProvider boolean options")
struct StructureRowProviderBooleanOptionsTests {
    private func makeManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.workingColumns = [
            EditableColumnDefinition(
                id: UUID(),
                name: "id",
                dataType: "INT",
                isNullable: false,
                defaultValue: nil,
                autoIncrement: true,
                unsigned: false,
                comment: nil,
                collation: nil,
                onUpdate: nil,
                charset: nil,
                extra: nil,
                isPrimaryKey: true
            ),
        ]
        return manager
    }

    private func makeProvider(tab: StructureTab = .columns) -> StructureRowProvider {
        StructureRowProvider(
            changeManager: makeManager(),
            tab: tab,
            databaseType: .postgresql,
            additionalFields: [.primaryKey, .onUpdate],
            serverSupport: .unrestricted,
            filterText: nil,
            sortDescriptor: nil
        )
    }

    @Test("Every boolean column supplies its own YES/NO options")
    func booleanColumnsSupplyOptions() {
        let provider = makeProvider()
        let options = provider.customDropdownOptions

        for field in [StructureColumnField.nullable, .primaryKey, .autoIncrement, .onUpdate] {
            guard let index = provider.orderedColumnFields.firstIndex(of: field) else {
                Issue.record("Field \(field) missing from the columns tab")
                continue
            }
            #expect(options[index]?.compactMap(\.sql) == ["YES", "NO"])
        }
    }

    /// A closed vocabulary has to contain whatever the grid drew, or the menu cannot show the
    /// current value as the selected one. The Default column is deliberately not closed: it holds
    /// an open-ended SQL expression, which is what its `Custom…` entry marks it as.
    @Test("A closed column's options are exactly what the grid draws")
    func optionsMatchRenderedValues() {
        let provider = makeProvider()
        let options = provider.customDropdownOptions

        for (index, value) in provider.rows[0].enumerated() {
            guard let allowed = options[index], let value else { continue }
            guard !allowed.contains(where: { if case .custom = $0 { return true } else { return false } }) else {
                continue
            }
            #expect(allowed.compactMap(\.sql).contains(value))
        }
    }

    @Test("The Default column is the one open vocabulary, and it can reach a value the menu lacks")
    func defaultColumnIsOpen() {
        let provider = makeProvider()
        guard let index = provider.orderedColumnFields.firstIndex(of: .defaultValue) else {
            Issue.record("PostgreSQL must offer a Default column")
            return
        }
        let options = provider.customDropdownOptions[index] ?? []
        #expect(options.contains(where: { if case .custom = $0 { return true } else { return false } }))
        #expect(options.contains(where: { if case .clear = $0 { return true } else { return false } }))
        #expect(options.compactMap(\.sql).contains("gen_random_uuid()"))
    }

    @Test("Every boolean column is also a dropdown column")
    func booleanColumnsAreDropdowns() {
        let provider = makeProvider()
        for index in provider.customDropdownOptions.keys {
            #expect(provider.dropdownColumns.contains(index))
        }
    }

    @Test("The index Unique column supplies YES/NO options")
    func indexUniqueSuppliesOptions() {
        let provider = makeProvider(tab: .indexes)
        #expect(provider.customDropdownOptions[3]?.compactMap(\.sql) == ["YES", "NO"])
    }

    @Test("No structure column reports itself as nullable, so Set NULL is never offered")
    func structureColumnsAreNeverNullable() {
        let provider = makeProvider()
        let rows = provider.asTableRows()
        #expect(!rows.columnNullable.isEmpty)
        for column in provider.columns {
            #expect(rows.columnNullable[column] == false)
        }
    }
}
