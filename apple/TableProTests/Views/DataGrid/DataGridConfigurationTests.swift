//
//  DataGridConfigurationTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
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

    @Test("A default grid offers value filters and column sort, edits nothing and colors no value by type")
    func defaults() {
        let configuration = DataGridConfiguration()

        #expect(configuration.supportsValueFilter)
        #expect(configuration.supportsColumnSort)
        #expect(configuration.showRowNumbers)
        #expect(!configuration.isEditable)
        #expect(configuration.commands.isEmpty)
        #expect(!configuration.colorsValuesByType)
        #expect(!configuration.overridesValueColorSetting)
    }

    // MARK: - Value colors

    @Test("The data tab, routine debug results and both comparison grids color values by type")
    func resultGridsColorValuesByType() async throws {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query))
        let result = PluginQueryResult(
            columns: ["total"],
            columnTypeNames: ["integer"],
            rows: [[.text("7")]],
            rowsAffected: 0,
            timing: PluginQueryTiming(total: 0)
        )
        let (routine, _) = RoutineDebugFixtures.controller(session: FakeDebugSession(performAnswer: .finished(result)))
        routine.start()
        try await waitUntil { routine.state.pausedLocation != nil && !routine.variables.isEmpty }
        routine.perform(.continueExecution)
        try await waitUntil { routine.hasEnded }
        let debugGrid = try #require(routine.resultGrid)

        #expect(fixture.coordinator.gridConfiguration(for: tab).colorsValuesByType)
        #expect(debugGrid.model.configuration.colorsValuesByType)
        #expect(CompareRowGridModel().model.configuration.colorsValuesByType)
        #expect(ResultComparisonGridModel().model.configuration.colorsValuesByType)
    }

    @Test("Table Listing draws its catalog rows in the grid text")
    func tableListingStaysPlain() {
        #expect(!TableListingTabView.gridConfiguration(databaseType: .mysql).colorsValuesByType)
    }

    @Test("Structure lists, Structure sections and data files draw values in the grid text")
    func definitionAndFileGridsStayPlain() throws {
        let list = StructureListGridModel<String>()
        list.load(
            columns: ["Name"],
            rows: [StructureListRow(id: "a", values: ["alpha"])],
            defaultWidths: [],
            minimumWidths: [],
            databaseType: .mysql,
            sortState: nil
        )
        let suite = try EphemeralDefaults()
        let editor = StructureDefinitionEditor(
            manager: StructureChangeManager(),
            context: .existingTable(
                connection: TestFixtures.makeConnection(type: .mysql),
                databaseName: "db",
                schemaName: nil,
                tableName: "t",
                objectKind: .table,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.refresh()

        #expect(!list.model.configuration.colorsValuesByType)
        #expect(!editor.adapter(for: .columns).model.configuration.colorsValuesByType)
        #expect(!DataFileContentView.gridConfiguration(for: DataFileController()).colorsValuesByType)
    }

    @Test("An agent session's rows draw values in the grid text")
    func agentRowsStayPlain() async throws {
        let run = AgentQueryRun(id: "1", sql: "select total from orders", resultJSON: #"{"columns":["total"],"rows":[["7"]]}"#)
        let window = ThemeTestFixture.host(
            AgentResultRowsView(runs: [run], artifacts: AgentArtifactCache(), connection: nil),
            size: NSSize(width: 600, height: 300)
        )
        defer { window.contentView = nil }

        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return Self.mainTable(in: window.contentView)?.controller?.model.rowCount == 1
        }
        let model = try #require(Self.mainTable(in: window.contentView)?.controller?.model)

        #expect(!model.configuration.colorsValuesByType)
    }

    private static func mainTable(in view: NSView?) -> DataGridTableView? {
        guard let view else { return nil }
        if let table = view as? DataGridTableView, table.paneKind == .main { return table }
        return view.subviews.lazy.compactMap { mainTable(in: $0) }.first
    }

    // MARK: - Sort

    @Test("Every data column sorts by its column identity, first click ascending outside row grids")
    func dataColumnsCarryASortPrototype() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        let prototypes = dataColumns(of: grid.main).map { $0.sortDescriptorPrototype }
        #expect(prototypes.map { $0?.key } == ["id", "name", "age"].map { DataGridColumnID(name: $0, occurrence: 0).stringValue })
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
        #expect(grid.main.sortDescriptors.map { $0.key } == [DataGridColumnID(name: "name", occurrence: 0).stringValue])

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

        #expect(descriptor.key == DataGridColumnID(name: "name", occurrence: 0).stringValue)
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
