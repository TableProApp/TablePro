//
//  QueryTabFilterPanel.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct QueryTabFilterPanel: View {
    @ObservedObject var coordinator: MainContentCoordinator
    /// The panel draws `coordinator.selectedTabFilterState`, which lives on `QueryTabManager.tabs`
    /// and not on the coordinator, so the store that publishes it has to be named here. Without it
    /// SwiftUI compares this view's own stored properties, finds them unchanged and skips `body`:
    /// the row `onAppear` adds reached the model and never reached the screen, so ⌘⇧F opened an
    /// empty bar with nothing to type into and the keystrokes went to the object list instead. That
    /// is what the two closures this view used to carry were hiding, because a closure is never
    /// equal to another one and forced a re-evaluation on every parent render. (#3026)
    @ObservedObject var tabManager: QueryTabManager
    /// Settings > Data Grid decides whether the panel holds the sort too.
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let columns: [String]
    let primaryKeyColumn: String?
    let databaseType: DatabaseType
    let enumValuesByColumn: [String: [String]]

    @State private var rawSQLCompletionProvider: RawSQLFilterCompletionProvider?
    @State private var fieldPaths: [PluginFieldPath] = []

    private static let sqlKeywords = [
        "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
        "IS NULL", "IS NOT NULL", "EXISTS",
        "CASE", "WHEN", "THEN", "ELSE", "END"
    ]

    var body: some View {
        FilterPanelView(
            state: coordinator.filterCoordinator.selectedTabFilterStateBinding,
            configuration: configuration,
            actions: coordinator.filterCoordinator
        )
        .onAppear {
            refreshRawSQLCompletionProvider()
        }
        .onChange(of: columns) { _ in
            refreshRawSQLCompletionProvider()
        }
        .onChange(of: suggestionSource) { _ in
            refreshRawSQLCompletionProvider()
        }
        .task(id: suggestionSource) {
            await loadFieldPaths()
        }
    }

    /// What both kinds of suggestion are read from: the table and the tab's scope. The name alone
    /// stayed equal across two tabs on `users` in two databases, so the second kept the first one's
    /// field paths and completions.
    private struct SuggestionSource: Hashable {
        let tableName: String?
        let scope: DatabaseScope?
    }

    private var suggestionSource: SuggestionSource {
        SuggestionSource(tableName: coordinator.currentTableName, scope: coordinator.selectedTabScope)
    }

    private var configuration: FilterPanelConfiguration {
        FilterPanelConfiguration(
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            enumValuesByColumn: enumValuesByColumn,
            fieldPaths: fieldPaths,
            valueCompletionKeywords: isSQLDialect ? Self.sqlKeywords : [],
            offersRawFilter: PluginManager.shared.supportsRawFilter(for: databaseType),
            rawFilterLabel: rawFilterLabel,
            rawSQLCompletionProvider: rawSQLCompletionProvider,
            caseMatching: .engine(PluginManager.shared.caseSensitivityStyle(for: databaseType)),
            offersMatchAny: PluginManager.shared.supportsMatchAnyFilters(for: databaseType),
            sqlPreview: coordinator.filterCoordinator,
            presetStore: FilterPresetStorage.shared,
            criteria: Self.criteriaConfiguration(
                settings: settingsManager.dataGrid,
                offersRawFilter: PluginManager.shared.supportsRawFilter(for: databaseType),
                isSQLDialect: isSQLDialect,
                supportsColumnSort: coordinator.supportsColumnSort,
                columns: columns,
                appliedSort: coordinator.filterCoordinator.selectedTabAppliedSortCriteria,
                actions: coordinator.filterCoordinator
            )
        )
    }

    /// Nil while the setting is off, which leaves the filter-only panel. Text mode is a WHERE
    /// condition, so it needs an engine that takes a raw filter and speaks SQL; a document store's
    /// raw filter is not a WHERE condition. The section is hidden where a table cannot be sorted by
    /// a column, and a new key sorts the way a first header click does.
    static func criteriaConfiguration(
        settings: DataGridSettings,
        offersRawFilter: Bool,
        isSQLDialect: Bool,
        supportsColumnSort: Bool,
        columns: [String],
        appliedSort: [FilterSortCriterion],
        actions: any FilterCriteriaActions
    ) -> FilterCriteriaConfiguration? {
        guard settings.showsSortInFilterPanel else { return nil }
        return FilterCriteriaConfiguration(
            offersTextMode: offersRawFilter && isSQLDialect,
            sortColumns: supportsColumnSort ? columns : nil,
            appliedSort: supportsColumnSort ? appliedSort : [],
            newSortDirection: settings.defaultSortDirection,
            actions: actions
        )
    }

    private var isSQLDialect: Bool {
        PluginManager.shared.sqlDialect(for: databaseType) != nil
    }

    /// "Raw SQL" is the wrong name on a store that takes a filter document rather than SQL.
    private var rawFilterLabel: String {
        isSQLDialect ? String(localized: "Raw SQL") : String(localized: "Raw Filter")
    }

    /// A relational driver reports no field paths, so this settles to an empty list without a
    /// round trip. `SQLSchemaProvider` caches per collection and folds concurrent callers into
    /// one sample, so reopening the panel does not resample.
    private func loadFieldPaths() async {
        guard let tableName = coordinator.currentTableName, !tableName.isEmpty,
              let scope = coordinator.selectedTabScope else {
            fieldPaths = []
            return
        }
        let provider = SchemaProviderRegistry.shared.getOrCreate(for: scope)
        let paths = await provider.fieldPaths(for: tableName)
        guard !Task.isCancelled else { return }
        fieldPaths = paths
    }

    private func refreshRawSQLCompletionProvider() {
        guard isSQLDialect,
              let tableName = coordinator.currentTableName,
              let scope = coordinator.selectedTabScope
        else {
            rawSQLCompletionProvider = nil
            return
        }
        let schemaProvider = SchemaProviderRegistry.shared.getOrCreate(for: scope)
        rawSQLCompletionProvider = RawSQLFilterCompletionProvider(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            tableName: tableName,
            connectionId: scope.connectionId
        )
    }
}
