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
        .onChange(of: coordinator.currentTableName) { _ in
            refreshRawSQLCompletionProvider()
        }
        .task(id: coordinator.currentTableName) {
            await loadFieldPaths()
        }
    }

    private var configuration: FilterPanelConfiguration {
        FilterPanelConfiguration(
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            enumValuesByColumn: enumValuesByColumn,
            fieldPaths: fieldPaths,
            valueCompletionKeywords: isSQLDialect ? Self.sqlKeywords : [],
            offersRawFilter: true,
            rawFilterLabel: rawFilterLabel,
            rawSQLCompletionProvider: rawSQLCompletionProvider,
            caseMatching: .engine(PluginManager.shared.caseSensitivityStyle(for: databaseType)),
            sqlPreview: coordinator.filterCoordinator,
            presetStore: FilterPresetStorage.shared
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
            tableName: tableName
        )
    }
}
