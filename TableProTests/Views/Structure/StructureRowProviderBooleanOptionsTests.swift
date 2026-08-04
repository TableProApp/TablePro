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
            #expect(options[index] == ["YES", "NO"])
        }
    }

    @Test("Offered options are exactly what the grid draws")
    func optionsMatchRenderedValues() {
        let provider = makeProvider()
        let options = provider.customDropdownOptions

        for (index, value) in provider.rows[0].enumerated() {
            guard let allowed = options[index], let value else { continue }
            #expect(allowed.contains(value))
        }
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
        #expect(provider.customDropdownOptions[3] == ["YES", "NO"])
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
