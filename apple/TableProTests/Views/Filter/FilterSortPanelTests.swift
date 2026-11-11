//
//  FilterSortPanelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StubCriteriaActions: FilterCriteriaActions {
    func applyFiltersAndSort() {}
    func filterConditionText(for filters: [TableFilter], logicMode: FilterLogicMode) -> String? { "" }
}

@MainActor
struct FilterSortPanelTests {
    private static let columns = ["id", "name", "email"]

    private func makeCoordinator(
        filters: [TableFilter] = [],
        sort: SortState = SortState(),
        type: DatabaseType = .mysql
    ) -> (coordinator: MainContentCoordinator, tabManager: QueryTabManager, tabId: UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: type),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "unfiltered", tabType: .table, tableName: "users")
        tab.sortState = sort
        tab.filterState.filters = filters
        tab.filterState.isVisible = true
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        let rows = (0..<3).map { index in Self.columns.map { PluginCellValue.fromOptional("\($0)_\(index)") } }
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: rows,
                columns: Self.columns,
                columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count)
            ),
            for: tab.id
        )
        return (coordinator, tabManager, tab.id)
    }

    private func tab(_ tabManager: QueryTabManager, _ tabId: UUID) throws -> QueryTab {
        try #require(tabManager.tabs.first { $0.id == tabId })
    }

    private func setSortDraft(_ draft: [FilterSortCriterion]?, in tabManager: QueryTabManager, _ tabId: UUID) throws {
        let index = try #require(tabManager.tabs.firstIndex { $0.id == tabId })
        tabManager.tabs[index].filterState.sortDraft = draft
    }

    // MARK: - Apply Filter & Sort

    @Test("Apply Filter & Sort runs the rows and the sort draft in one query")
    func appliesFiltersAndSortTogether() throws {
        let name = TestFixtures.makeTableFilter(column: "name", value: "a")
        let (coordinator, tabManager, tabId) = makeCoordinator(filters: [name])
        defer { coordinator.teardown() }
        try setSortDraft([FilterSortCriterion(columnName: "email", direction: .descending)], in: tabManager, tabId)

        coordinator.filterCoordinator.applyFiltersAndSort()

        let applied = try tab(tabManager, tabId)
        #expect(applied.sortState == SortState(
            columns: [SortColumn(columnIndex: 2, direction: .descending, columnName: "email")],
            source: .user
        ))
        #expect(applied.content.query.contains("WHERE `name`"))
        #expect(applied.content.query.contains("ORDER BY `email` DESC"))
        #expect(applied.filterState.commit == .all)
        #expect(applied.filterState.executedFilters.map { $0.id } == [name.id])
        #expect(applied.filterState.sortDraft == nil)
        #expect(applied.hasUserInteraction)
        let appliedSort = coordinator.filterCoordinator.selectedTabAppliedSortCriteria
        #expect(appliedSort == [FilterSortCriterion(columnName: "email", direction: .descending)])
        #expect(!applied.filterState.criteriaDiffer(fromAppliedSort: appliedSort))
    }

    @Test("With no row to run, the sort alone reloads the table and the rows stay in the panel")
    func sortOnlyApplyKeepsRowsUnapplied() throws {
        let unfinished = TestFixtures.makeTableFilter(column: "name", value: "")
        let (coordinator, tabManager, tabId) = makeCoordinator(filters: [unfinished])
        defer { coordinator.teardown() }
        try setSortDraft([FilterSortCriterion(columnName: "id", direction: .ascending)], in: tabManager, tabId)

        coordinator.filterCoordinator.applyFiltersAndSort()

        let applied = try tab(tabManager, tabId)
        #expect(!applied.content.query.contains("WHERE"))
        #expect(applied.content.query.contains("ORDER BY `id` ASC"))
        #expect(applied.filterState.commit == nil)
        #expect(applied.filterState.filters == [unfinished])
        #expect(applied.sortState.columns.compactMap { $0.columnName } == ["id"])
    }

    @Test("A draft equal to the tab's sort leaves the sort and its source alone")
    func unchangedDraftKeepsTheSort() throws {
        let defaultSort = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending, columnName: "id")],
            source: .defaultSort
        )
        let (coordinator, tabManager, tabId) = makeCoordinator(sort: defaultSort)
        defer { coordinator.teardown() }
        try setSortDraft([FilterSortCriterion(columnName: "id", direction: .ascending)], in: tabManager, tabId)

        coordinator.filterCoordinator.applyFiltersAndSort()

        let applied = try tab(tabManager, tabId)
        #expect(applied.sortState == defaultSort)
        #expect(applied.filterState.sortDraft == nil)
    }

    @Test("A filter the engine refuses leaves the sort, the draft and the query as they were")
    func refusalKeepsTheDraft() throws {
        let refused = TableFilter.rawCondition("status = 'a' -- temp")
        let (coordinator, tabManager, tabId) = makeCoordinator(filters: [refused])
        defer { coordinator.teardown() }
        let draft = [FilterSortCriterion(columnName: "name", direction: .ascending)]
        try setSortDraft(draft, in: tabManager, tabId)

        coordinator.filterCoordinator.applyFiltersAndSort()

        let after = try tab(tabManager, tabId)
        #expect(after.content.query == "unfiltered")
        #expect(after.sortState == SortState())
        #expect(after.filterState.sortDraft == draft)
        #expect(after.filterState.commit == nil)
        #expect(after.execution.errorMessage != nil)
    }

    @Test("A header sort runs at once and the section follows it")
    func headerSortClearsTheDraft() throws {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        try setSortDraft([FilterSortCriterion(columnName: "email", direction: .ascending)], in: tabManager, tabId)

        coordinator.handleSortStateChanged(SortState(
            columns: [SortColumn(columnIndex: 1, direction: .descending)],
            source: .user
        ))

        let after = try tab(tabManager, tabId)
        #expect(after.filterState.sortDraft == nil)
        #expect(coordinator.filterCoordinator.selectedTabAppliedSortCriteria == [
            FilterSortCriterion(columnName: "name", direction: .descending)
        ])
    }

    // MARK: - Text mode

    @Test("Text mode starts from the enabled rows' WHERE condition, without the keyword")
    func conditionTextFromEnabledRows() throws {
        let (coordinator, _, _) = makeCoordinator()
        defer { coordinator.teardown() }
        let rows = [
            TestFixtures.makeTableFilter(column: "name", op: .greaterThan, value: "a"),
            TestFixtures.makeTableFilter(column: "email", value: "b", isEnabled: false),
            TableFilter.rawCondition("id > 1")
        ]

        let text = coordinator.filterCoordinator.filterConditionText(for: rows, logicMode: .or)

        #expect(text == "`name` > 'a' OR (id > 1)")
        #expect(coordinator.filterCoordinator.filterConditionText(for: [], logicMode: .and) == "")
    }

    @Test("A row the engine cannot write as SQL refuses the switch")
    func refusedRowHasNoConditionText() {
        let (coordinator, _, _) = makeCoordinator()
        defer { coordinator.teardown() }

        let text = coordinator.filterCoordinator.filterConditionText(
            for: [TableFilter.rawCondition("1=1); DELETE FROM users")],
            logicMode: .and
        )

        #expect(text == nil)
    }

    @Test("Text mode's one raw row applies like any row")
    func textModeApplies() throws {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        let index = try #require(tabManager.tabs.firstIndex { $0.id == tabId })
        tabManager.tabs[index].filterState.enterTextMode(condition: "`id` > 1")

        coordinator.filterCoordinator.applyFiltersAndSort()

        let applied = try tab(tabManager, tabId)
        #expect(applied.content.query.contains("WHERE (`id` > 1)"))
        #expect(applied.filterState.effectiveEditMode == .text)
        #expect(!applied.filterState.criteriaDiffer(fromAppliedSort: []))
    }

    // MARK: - Edited state and Apply

    /// The configuration the panel builds for the selected tab with the setting on.
    private func criteria(_ coordinator: MainContentCoordinator) throws -> FilterCriteriaConfiguration {
        var settings = DataGridSettings.default
        settings.showsSortInFilterPanel = true
        let filters: FilterCoordinator = coordinator.filterCoordinator
        return try #require(QueryTabFilterPanel.criteriaConfiguration(
            settings: settings,
            offersRawFilter: true,
            isSQLDialect: true,
            supportsColumnSort: true,
            columns: Self.columns,
            appliedSort: filters.selectedTabAppliedSortCriteria,
            runningCondition: filters.selectedTabRunningCondition,
            actions: filters
        ))
    }

    @Test("Builder to Text with nothing typed is not an edit, and typing other text is")
    func switchingToTextIsNotAnEdit() throws {
        let raw = TableFilter.rawCondition("id > 1")
        let name = TestFixtures.makeTableFilter(column: "name", value: "a")
        let (coordinator, tabManager, tabId) = makeCoordinator(filters: [raw, name])
        defer { coordinator.teardown() }
        coordinator.filterCoordinator.applyFiltersAndSort()
        let index = try #require(tabManager.tabs.firstIndex { $0.id == tabId })
        let applied = tabManager.tabs[index].filterState
        #expect(try !criteria(coordinator).isEdited(applied))

        let condition = try #require(coordinator.filterCoordinator.filterConditionText(
            for: applied.filters,
            logicMode: applied.filterLogicMode
        ))
        tabManager.tabs[index].filterState.enterTextMode(condition: condition)

        #expect(coordinator.filterCoordinator.selectedTabRunningCondition == condition)
        #expect(try !criteria(coordinator).isEdited(tabManager.tabs[index].filterState))

        tabManager.tabs[index].filterState.setTextCondition("id > 2")
        #expect(try criteria(coordinator).isEdited(tabManager.tabs[index].filterState))

        tabManager.tabs[index].filterState.setTextCondition(condition)
        tabManager.tabs[index].filterState.enterBuilderMode()
        #expect(coordinator.filterCoordinator.selectedTabRunningCondition == nil)
        #expect(try !criteria(coordinator).isEdited(tabManager.tabs[index].filterState))
    }

    @Test("Apply Filter & Sort is prominent while the criteria are edited and plain once they are applied")
    func applyIsProminentOnlyWhileEdited() throws {
        let name = TestFixtures.makeTableFilter(column: "name", value: "a")
        let (coordinator, tabManager, tabId) = makeCoordinator(filters: [name])
        defer { coordinator.teardown() }
        let index = try #require(tabManager.tabs.firstIndex { $0.id == tabId })
        #expect(try criteria(coordinator).applyIsProminent(for: tabManager.tabs[index].filterState))

        coordinator.filterCoordinator.applyFiltersAndSort()
        #expect(try !criteria(coordinator).applyIsProminent(for: tabManager.tabs[index].filterState))

        try setSortDraft([FilterSortCriterion(columnName: "email", direction: .descending)], in: tabManager, tabId)
        #expect(try criteria(coordinator).applyIsProminent(for: tabManager.tabs[index].filterState))

        coordinator.filterCoordinator.applyFiltersAndSort()
        #expect(try !criteria(coordinator).applyIsProminent(for: tabManager.tabs[index].filterState))
    }

    // MARK: - Starting row

    @Test("A cell's Filter menu runs its condition in place of the panel's untouched starting row")
    func cellFilterReplacesTheStartingRow() throws {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        let index = try #require(tabManager.tabs.firstIndex { $0.id == tabId })
        tabManager.tabs[index].filterState.addStartingFilter(
            settings: FilterSettings(defaultColumn: .rawSQL),
            columns: Self.columns,
            primaryKeyColumn: "id",
            offersRawFilter: true,
            isReplaceable: true
        )
        let cell = TestFixtures.makeTableFilter(column: "name", value: "name_1")

        coordinator.filterCoordinator.applyCellFilter(cell)

        let after = try tab(tabManager, tabId)
        #expect(after.filterState.filters.map { $0.id } == [cell.id])
        #expect(after.filterState.executedFilters.map { $0.id } == [cell.id])
        #expect(after.content.query.contains("WHERE `name`"))
    }

    @Test("Only the data view settings let an incoming filter replace the starting row")
    func startingRowReplacementFollowsTheSettings() {
        #expect(!QueryTabFilterPanel.replacesUntouchedStartingRow(settings: .default))

        var sortInPanel = DataGridSettings.default
        sortInPanel.showsSortInFilterPanel = true
        #expect(QueryTabFilterPanel.replacesUntouchedStartingRow(settings: sortInPanel))

        var opensPanel = DataGridSettings.default
        opensPanel.opensFilterPanelForTables = true
        #expect(QueryTabFilterPanel.replacesUntouchedStartingRow(settings: opensPanel))
    }

    // MARK: - Settings

    @Test("Both settings start off and decode off from settings saved before them")
    func settingsDefaultOff() throws {
        #expect(DataGridSettings.default.showsSortInFilterPanel == false)
        #expect(DataGridSettings.default.opensFilterPanelForTables == false)

        let legacy = try JSONDecoder().decode(DataGridSettings.self, from: Data(#"{"showRowNumbers":false}"#.utf8))
        #expect(legacy.showsSortInFilterPanel == false)
        #expect(legacy.opensFilterPanelForTables == false)
        #expect(legacy.showRowNumbers == false)

        var on = DataGridSettings.default
        on.showsSortInFilterPanel = true
        on.opensFilterPanelForTables = true
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: JSONEncoder().encode(on))
        #expect(decoded == on)
    }

    @Test("With the setting off the panel gets no sort, no Text mode and no combined Apply")
    func settingOffLeavesThePlainPanel() {
        let off = QueryTabFilterPanel.criteriaConfiguration(
            settings: .default,
            offersRawFilter: true,
            isSQLDialect: true,
            supportsColumnSort: true,
            columns: Self.columns,
            appliedSort: [],
            actions: StubCriteriaActions()
        )
        let isOff = off == nil
        #expect(isOff)
    }

    @Test("With the setting on, Text mode needs a SQL raw filter and the section needs a column sort")
    func settingOnGatesEachPart() throws {
        var settings = DataGridSettings.default
        settings.showsSortInFilterPanel = true
        settings.defaultSortDirection = .descending
        let actions = StubCriteriaActions()

        let sql = try #require(QueryTabFilterPanel.criteriaConfiguration(
            settings: settings, offersRawFilter: true, isSQLDialect: true, supportsColumnSort: true,
            columns: Self.columns, appliedSort: [], actions: actions
        ))
        #expect(sql.offersTextMode)
        #expect(sql.sortColumns == Self.columns)
        #expect(sql.newSortDirection == .descending)

        let document = try #require(QueryTabFilterPanel.criteriaConfiguration(
            settings: settings, offersRawFilter: true, isSQLDialect: false, supportsColumnSort: true,
            columns: Self.columns, appliedSort: [], actions: actions
        ))
        #expect(!document.offersTextMode)

        let unsortable = try #require(QueryTabFilterPanel.criteriaConfiguration(
            settings: settings, offersRawFilter: false, isSQLDialect: true, supportsColumnSort: false,
            columns: Self.columns,
            appliedSort: [FilterSortCriterion(columnName: "id", direction: .ascending)],
            actions: actions
        ))
        #expect(!unsortable.offersTextMode)
        #expect(!unsortable.showsSort)
        #expect(unsortable.appliedSort.isEmpty)
    }

    @Test("Opening a table opens the panel only when the setting asks")
    func openingATableOpensThePanel() {
        let settings = FilterSettings(restoreBehavior: .restoreAndApply, alwaysShowPanel: false)
        let nothingSaved = PersistedFilterState(filters: [])

        let off = FilterCoordinator.resolvedRestoredState(
            settings: settings, saved: nothingSaved, current: TabFilterState()
        )
        let on = FilterCoordinator.resolvedRestoredState(
            settings: settings, saved: nothingSaved, current: TabFilterState(), opensPanel: true
        )

        #expect(!off.isVisible)
        #expect(on.isVisible)
    }
}
