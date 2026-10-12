//
//  SidebarFilterBanner.swift
//  TablePro
//

import SwiftUI

/// A filtered list looks exactly like a short one, so the sidebar says it is filtered.
struct SidebarFilterBanner: View {
    let label: String
    let showAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(String(localized: "Show All"), action: showAll)
                .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// The schema filter's banner for one database, shown while the filter keeps anything at all.
struct SidebarSchemaFilterBanner: View {
    let connectionId: UUID
    let database: String?
    let databaseType: DatabaseType
    @ObservedObject var sidebarState: SharedSidebarState

    @ObservedObject private var treeService = DatabaseTreeMetadataService.shared
    @ObservedObject private var schemaService = SchemaService.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared

    private var summary: DatabaseTreeVisibility.Summary? {
        let selected = sidebarState.schemaFilter(for: database)
        guard !selected.isEmpty,
              let schemas = SidebarSchemaFilter().schemaList(connectionId: connectionId, database: database ?? "")
        else { return nil }
        let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: databaseType))
        let showsSystem = settingsManager.general.showSystemContainers
        guard DatabaseTreeVisibility.isFilteringSchemas(
            selected: selected, schemas: schemas, systemSchemas: systemSchemas, showsSystem: showsSystem
        ) else { return nil }
        return DatabaseTreeVisibility.schemaSummary(
            schemas: schemas, selected: selected, systemSchemas: systemSchemas, showsSystem: showsSystem
        )
    }

    var body: some View {
        if let summary {
            SidebarFilterBanner(
                label: String(
                    format: String(localized: "Showing %1$lld of %2$lld schemas"),
                    summary.shown,
                    summary.total
                ),
                showAll: { sidebarState.setSchemaFilter([], for: database) }
            )
            Divider()
        }
    }
}
