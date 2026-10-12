//
//  DatabaseTreeFilterPopover.swift
//  TablePro
//

import SwiftUI

internal enum SidebarFilterTarget: Equatable {
    case databases
    case schemas(database: String?)
}

struct DatabaseTreeFilterPopover: View {
    let connectionId: UUID
    let target: SidebarFilterTarget
    let onChange: (Set<String>) -> Void

    @ObservedObject private var treeService = DatabaseTreeMetadataService.shared
    @ObservedObject private var schemaService = SchemaService.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @State private var selection: Set<String>
    @State private var searchText: String = ""

    private static let width: CGFloat = 300

    init(
        connectionId: UUID,
        target: SidebarFilterTarget,
        selection: Set<String>,
        onChange: @escaping (Set<String>) -> Void
    ) {
        self.connectionId = connectionId
        self.target = target
        self.onChange = onChange
        _selection = State(initialValue: selection)
    }

    private var showsSystemContainers: Bool {
        settingsManager.general.showSystemContainers
    }

    private var databases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
    }

    private var schemaDatabase: String {
        guard case .schemas(let database) = target else { return "" }
        return database ?? ""
    }

    private var schemas: [String]? {
        SidebarSchemaFilter().schemaList(connectionId: connectionId, database: schemaDatabase)
    }

    private var systemSchemas: Set<String> {
        guard let type = DatabaseManager.shared.session(for: connectionId)?.connection.type else { return [] }
        return Set(PluginManager.shared.systemSchemaNames(for: type))
    }

    private var candidates: [String] {
        switch target {
        case .databases:
            return DatabaseTreeVisibility.filterCandidates(databases, showsSystem: showsSystemContainers).map(\.name)
        case .schemas:
            return DatabaseTreeVisibility.schemaFilterCandidates(
                schemas ?? [], systemSchemas: systemSchemas, showsSystem: showsSystemContainers
            )
        }
    }

    private var matchingCandidates: [String] {
        guard !searchText.isEmpty else { return candidates }
        return candidates.filter { SidebarNameFilter.matches(query: searchText, candidate: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: Self.width)
    }

    private var searchField: some View {
        NativeSearchField(
            text: $searchText,
            placeholder: searchPlaceholder,
            controlSize: .small
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if candidates.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if matchingCandidates.isEmpty {
            UnavailableStateView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            candidateList
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch target {
        case .databases:
            UnavailableStateView(
                String(localized: "No Databases"),
                systemImage: "cylinder",
                description: Text(String(localized: "Connect to load the database list."))
            )
        case .schemas:
            UnavailableStateView(
                String(localized: "No Schemas"),
                systemImage: "folder",
                description: Text(String(localized: "Connect to load the schema list."))
            )
        }
    }

    private var candidateList: some View {
        List {
            ForEach(matchingCandidates, id: \.self) { name in
                Toggle(name, isOn: binding(for: name))
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 160, maxHeight: 320)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Show All")) {
                commit([])
            }
            .buttonStyle(.borderless)
            .disabled(!isFiltering)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchPlaceholder: String {
        switch target {
        case .databases: return String(localized: "Search databases")
        case .schemas: return String(localized: "Search schemas")
        }
    }

    private var isFiltering: Bool {
        switch target {
        case .databases:
            return DatabaseTreeVisibility.isFiltering(
                selected: selection, databases: databases, showsSystem: showsSystemContainers
            )
        case .schemas:
            return DatabaseTreeVisibility.isFilteringSchemas(
                selected: selection, schemas: schemas, systemSchemas: systemSchemas, showsSystem: showsSystemContainers
            )
        }
    }

    private var countLabel: String {
        switch target {
        case .databases:
            guard isFiltering else { return String(localized: "Showing all databases") }
            let summary = DatabaseTreeVisibility.summary(
                databases: databases, selected: selection, showsSystem: showsSystemContainers
            )
            return String(format: String(localized: "Showing %1$lld of %2$lld"), summary.shown, summary.total)
        case .schemas:
            guard isFiltering else { return String(localized: "Showing all schemas") }
            let summary = DatabaseTreeVisibility.schemaSummary(
                schemas: schemas ?? [],
                selected: selection,
                systemSchemas: systemSchemas,
                showsSystem: showsSystemContainers
            )
            return String(format: String(localized: "Showing %1$lld of %2$lld schemas"), summary.shown, summary.total)
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(name) },
            set: { isOn in
                var updated = selection
                if isOn {
                    updated.insert(name)
                } else {
                    updated.remove(name)
                }
                commit(updated)
            }
        )
    }

    private func commit(_ updated: Set<String>) {
        selection = updated
        onChange(updated)
    }
}
