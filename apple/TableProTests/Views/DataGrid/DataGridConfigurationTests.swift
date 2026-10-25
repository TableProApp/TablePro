//
//  DataGridConfigurationTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridConfigurationTests {
    private func dataColumns(of table: NSTableView) -> [NSTableColumn] {
        table.tableColumns.filter { $0.identifier != DataGridPane.rowNumberIdentifier }
    }

    private func hasAttachment(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func sorted(by name: String, ascending: Bool) -> InMemoryDataGridStateStore {
        let store = InMemoryDataGridStateStore()
        store.sortState = SortState(
            columns: [SortColumn(columnIndex: 1, direction: ascending ? .ascending : .descending, columnName: name)],
            source: .user
        )
        return store
    }

    @Test("A default grid offers value filters and column sort, and edits nothing")
    func defaults() {
        let configuration = DataGridConfiguration()

        #expect(configuration.supportsValueFilter)
        #expect(configuration.supportsColumnSort)
        #expect(configuration.showRowNumbers)
        #expect(!configuration.isEditable)
        #expect(configuration.commands.isEmpty)
    }

    // MARK: - Sort

    @Test("Every data column sorts by its column identity, first click ascending outside row grids")
    func dataColumnsCarryASortPrototype() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        let prototypes = dataColumns(of: grid.main).map { $0.sortDescriptorPrototype }
        #expect(prototypes.map { $0?.key } == ["id", "name", "age"])
        #expect(prototypes.allSatisfy { $0?.ascending == true })
    }

    @Test("A grid that cannot be ordered by a column offers no sort on its headers")
    func noColumnSortRemovesPrototypes() {
        var configuration = DataGridConfiguration()
        configuration.supportsColumnSort = false
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration)
        defer { grid.close() }

        #expect(dataColumns(of: grid.main).allSatisfy { $0.sortDescriptorPrototype == nil })
    }

    @Test("Turning column sort off on an open grid takes the sort away from its headers")
    func columnSortOffLive() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people, store: Self.sorted(by: "name", ascending: false))
        defer { grid.close() }
        #expect(grid.main.sortDescriptors.map { $0.key } == ["name"])

        grid.model.configuration.supportsColumnSort = false

        #expect(dataColumns(of: grid.main).allSatisfy { $0.sortDescriptorPrototype == nil })
        #expect(grid.main.sortDescriptors.isEmpty)
    }

    @Test("Without column sort a header sort change reaches no owner")
    func noColumnSortIgnoresHeaderSort() {
        var configuration = DataGridConfiguration()
        configuration.supportsColumnSort = false
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration)
        defer { grid.close() }

        grid.main.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        #expect(grid.owner.sortChanges.isEmpty)
        #expect(!grid.model.store.sortState.isSorting)
    }

    @Test("The stored sort shows on the header, with its direction for accessibility")
    func storedSortShowsOnTheHeader() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people, store: Self.sorted(by: "name", ascending: false))
        defer { grid.close() }
        let descriptor = try #require(grid.main.sortDescriptors.first)
        let name = try #require(grid.tableColumn(named: "name"))
        let age = try #require(grid.tableColumn(named: "age"))

        #expect(descriptor.key == "name")
        #expect(!descriptor.ascending)
        #expect(name.headerCell.accessibilitySortDirection() == .descending)
        #expect(age.headerCell.accessibilitySortDirection() == .unknown)
    }

    // MARK: - Value filter

    @Test("A filtered column's heading carries the funnel when the grid offers value filters")
    func funnelShowsWithValueFilters() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people) { _, model in
            model.store.valueFilter = GridFixtureRows.nameFilter(["bob"])
        }
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))
        let age = try #require(grid.tableColumn(named: "age"))

        #expect(grid.model.rowCount == 1)
        #expect(hasAttachment(name.headerCell.attributedStringValue))
        #expect(!hasAttachment(age.headerCell.attributedStringValue))
    }

    @Test("A grid without value filters shows a plain heading")
    func noFunnelWithoutValueFilters() throws {
        var configuration = DataGridConfiguration()
        configuration.supportsValueFilter = false
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration) { _, model in
            model.store.valueFilter = GridFixtureRows.nameFilter(["bob"])
        }
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))

        #expect(!hasAttachment(name.headerCell.attributedStringValue))
        #expect(name.headerCell.stringValue == "name")
    }

    @Test("Clearing the filter puts the plain heading back")
    func clearingTheFilterDropsTheFunnel() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people) { _, model in
            model.store.valueFilter = GridFixtureRows.nameFilter(["bob"])
        }
        defer { grid.close() }

        grid.model.setValueFilter(GridValueFilterState())

        let name = try #require(grid.tableColumn(named: "name"))
        #expect(grid.model.rowCount == 5)
        #expect(!hasAttachment(name.headerCell.attributedStringValue))
    }

    // MARK: - Headers

    @Test("A heading's tooltip names the column and its type")
    func headerToolTipNamesTheType() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))

        #expect(name.headerToolTip == "name (TEXT)")
    }

    @Test("A heading tells accessibility which column it heads")
    func headerAccessibilityLabel() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))

        #expect(name.headerCell.accessibilityLabel() == String(format: String(localized: "Column: %@"), "name"))
    }
}
