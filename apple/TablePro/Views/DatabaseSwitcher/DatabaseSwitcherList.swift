//
//  DatabaseSwitcherList.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

// The searchable container list the toolbar chooser and the restore picker share.
struct DatabaseSwitcherList: View {
    // What the chooser offers beyond picking a row. Nil leaves only picking, favorites and Copy Name.
    struct ContainerCommands {
        let isReadOnly: Bool
        let schemaEditEligibility: SchemaEditEligibility.Context
        let onRequestCreate: () -> Void
        let onRequestDrop: ([DatabaseContainerRef]) -> Void
        let onRequestExport: ([DatabaseContainerRef]) -> Void
        let onRequestEdit: (DatabaseContainerRef) -> Void
    }

    @ObservedObject var viewModel: DatabaseSwitcherViewModel
    let currentDatabase: String?
    // The database the rows belong to; in schema mode the rows are schemas inside it.
    let activeDatabase: String
    let databaseType: DatabaseType
    let connectionId: UUID
    let commands: ContainerCommands?
    let onCommit: (String) -> Void
    // The host owns the surface: an AppKit popover or panel, or a flow's sheet.
    let dismiss: () -> Void

    @State private var supportsCreateDatabase = false
    @State private var favoriteDatabases: Set<String> = []

    private var switchTarget: ContainerSwitchTarget { viewModel.switchTarget }

    private var supportsDropDatabase: Bool {
        PluginManager.shared.supportsDropDatabase(for: databaseType)
    }
    private var supportsDropSchema: Bool {
        PluginManager.shared.supportsDropSchema(for: databaseType)
    }
    private var showsCreateRow: Bool {
        guard let commands, !commands.isReadOnly else { return false }
        switch switchTarget {
        case .database: return supportsCreateDatabase
        case .schema: return SchemaEditEligibility.canCreate(context: commands.schemaEditEligibility)
        }
    }
    private var containerName: String {
        switch switchTarget {
        case .database: PluginManager.shared.containerEntityName(for: databaseType)
        case .schema: PluginManager.shared.schemaEntityName(for: databaseType)
        }
    }
    private var containerNamePlural: String {
        containerName + "s"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content

            if showsCreateRow {
                Divider()
                createButton
            }
        }
        .background(refreshShortcut)
        .task { await viewModel.fetchDatabases() }
        .task { await refreshCreateSupport() }
        .onAppear { reloadFavorites() }
        .onReceive(NotificationCenter.default.publisher(for: .favoriteDatabasesDidChange)) { _ in
            reloadFavorites()
        }
    }

    private var refreshShortcut: some View {
        Button("") {
            Task { await viewModel.refreshDatabases() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .hidden()
    }

    private var searchField: some View {
        NativeSearchField(
            text: $viewModel.searchText,
            placeholder: String(format: String(localized: "Search %@"), containerNamePlural.lowercased()),
            onMoveUp: { viewModel.moveUp() },
            onMoveDown: { viewModel.moveDown() },
            onSubmit: { commitSelection() },
            focusOnAppear: true
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            loadingView
        } else if let error = viewModel.errorMessage {
            errorView(error)
        } else if switchTarget == .database,
                  PluginManager.shared.connectionMode(for: databaseType) == .fileBased {
            sqliteState
        } else if viewModel.filteredDatabases.isEmpty {
            emptyState
        } else {
            list
        }
    }

    // The search field keeps focus for the whole flow, so the list only presents its selection.
    private var list: some View {
        FieldDrivenList(
            sections: listSections,
            selection: $viewModel.selectedDatabases,
            allowsMultipleSelection: commands != nil,
            onPrimaryAction: { name in
                viewModel.selectedDatabase = name
                commitSelection()
            },
            menuItems: { contextMenuItems(for: $0) },
            row: { row(for: $0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Unlike the sidebar tree, a switcher lists every container the server returned (#2832).
    private var listSections: [FieldDrivenListSection<DatabaseMetadata>] {
        let sections = viewModel.visibleSections
        return [
            FieldDrivenListSection(id: "containers", items: sections.user),
            FieldDrivenListSection(id: "system", title: String(localized: "System"), items: sections.system)
        ]
    }

    private func row(for database: DatabaseMetadata) -> some View {
        let isCurrent = database.name == currentDatabase
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .selectionAwareTint(Color.accentColor)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 14)
                .accessibilityLabel(
                    Text(String(format: String(localized: "Current %@"), containerName.lowercased()))
                )
                .accessibilityHidden(!isCurrent)

            Image(systemName: database.icon)
                .font(.body)
                .selectionAwareTint(database.isSystemDatabase ? Color.secondary : Color.accentColor)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(database.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            favoriteIndicator(for: database)
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    // A glyph, not a button: the hosting cell returns nil from hitTest, so the toggle lives in the menu.
    @ViewBuilder
    private func favoriteIndicator(for database: DatabaseMetadata) -> some View {
        let isFavorite = switchTarget == .database && favoriteDatabases.contains(database.name)
        Image(systemName: "star.fill")
            .font(.caption)
            .selectionAwareTint(Color.yellow)
            .opacity(isFavorite ? 1 : 0)
            .accessibilityLabel(Text(String(localized: "Favorite")))
            .accessibilityHidden(!isFavorite)
    }

    private func contextMenuItems(for selection: Set<String>) -> [FieldDrivenMenuItem] {
        let targets = containerRefs(for: selection)
        var items: [FieldDrivenMenuItem] = favoriteItems(for: targets)

        if !targets.isEmpty {
            let copyTitle = targets.count == 1
                ? String(localized: "Copy Name")
                : String(format: String(localized: "Copy %lld Names"), targets.count)
            items.append(FieldDrivenMenuItem(title: copyTitle) {
                ClipboardService.shared.writeText(targets.map(\.name).joined(separator: ","))
            })
        }
        guard let commands else { return items }

        // The same reachability check the sidebar's Export item makes.
        if !targets.isEmpty, ExportPreselection.canPreselect(
            containers: targets,
            activeDatabase: activeDatabase,
            canReachOtherDatabases: databaseType.supportsConnectionPooling
        ) {
            items.append(FieldDrivenMenuItem(title: String(localized: "Export…")) {
                dismiss()
                commands.onRequestExport(targets)
            })
        }

        if let editable = SchemaEditEligibility.editable(targets, context: commands.schemaEditEligibility) {
            items.append(.separator)
            items.append(
                FieldDrivenMenuItem(
                    title: String(format: String(localized: "Edit %@\u{2026}"), containerName)
                ) {
                    dismiss()
                    commands.onRequestEdit(editable)
                }
            )
        }

        let droppable = ContainerDropEligibility.droppable(
            targets, context: dropEligibilityContext(isReadOnly: commands.isReadOnly)
        )
        if !droppable.isEmpty {
            items.append(.separator)
            items.append(FieldDrivenMenuItem(title: dropMenuTitle(for: droppable)) {
                dismiss()
                commands.onRequestDrop(droppable)
            })
        }
        return items
    }

    // Schema names in the database favorites store would be favorites that name nothing.
    private func reloadFavorites() {
        guard switchTarget == .database else { return }
        favoriteDatabases = Set(
            FavoriteDatabasesStorage.shared.favorites(for: connectionId).map(\.database)
        )
    }

    private func favoriteItems(for targets: [DatabaseContainerRef]) -> [FieldDrivenMenuItem] {
        guard switchTarget == .database else { return [] }
        let databases = targets.filter { $0.kind == .database }.compactMap(\.database)
        guard !databases.isEmpty else { return [] }

        let stored = FavoriteDatabasesStorage.shared.favorites(for: connectionId)
        let environments = Dictionary(
            stored.map { ($0.database, $0.environment) },
            uniquingKeysWith: { first, _ in first }
        )
        let state = FavoriteDatabaseSelectionState(environments: databases.map { environments[$0] })

        var items: [FieldDrivenMenuItem] = [
            FieldDrivenMenuItem(
                title: FavoriteDatabaseMenu.submenuTitle(for: state),
                submenu: FavoriteDatabaseMenu.environmentItems(for: state).map { item in
                    FieldDrivenMenuItem(title: item.title, isOn: item.isOn) {
                        for database in databases {
                            FavoriteDatabasesStorage.shared.setFavorite(
                                database: database,
                                environment: item.environment,
                                connectionId: connectionId
                            )
                        }
                    }
                }
            )
        ]
        if state.hasFavorite {
            items.append(FieldDrivenMenuItem(title: FavoriteDatabaseMenu.removeTitle) {
                for database in databases {
                    FavoriteDatabasesStorage.shared.removeFavorite(
                        database: database,
                        connectionId: connectionId
                    )
                }
            })
        }
        items.append(.separator)
        return items
    }

    // A schema row needs a schema ref, or Drop reaches dropDatabase and Export cannot resolve it.
    private func containerRefs(for selection: Set<String>) -> [DatabaseContainerRef] {
        viewModel.filteredDatabases
            .filter { selection.contains($0.name) }
            .map { item in
                switch switchTarget {
                case .database:
                    return .database(item.name, isSystem: item.isSystemDatabase)
                case .schema:
                    return .schema(
                        database: activeDatabase, schema: item.name, isSystem: item.isSystemDatabase
                    )
                }
            }
    }

    private func dropMenuTitle(for targets: [DatabaseContainerRef]) -> String {
        DatabaseDropRequest(
            targets: targets,
            entityName: containerName,
            entityNamePlural: containerNamePlural
        ).menuTitle
    }

    private func dropEligibilityContext(isReadOnly: Bool) -> ContainerDropEligibility.Context {
        ContainerDropEligibility.Context(
            activeDatabase: activeDatabase,
            activeSchema: switchTarget == .schema ? currentDatabase : nil,
            supportsDropDatabase: supportsDropDatabase,
            supportsDropSchema: supportsDropSchema,
            isReadOnly: isReadOnly
        )
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(String(format: String(localized: "Loading %@…"), containerNamePlural.lowercased()))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(String(format: String(localized: "Failed to load %@"), containerNamePlural.lowercased()))
                .font(.callout.weight(.medium))
            RevealedTextView(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button(String(localized: "Retry")) {
                Task { await viewModel.fetchDatabases() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var sqliteState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(String(localized: "SQLite is file-based"))
                .font(.callout.weight(.medium))
            Text(String(localized: "Open a different file from the Welcome window."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            if viewModel.searchText.isEmpty {
                Text(String(format: String(localized: "No %@"), containerNamePlural.lowercased()))
                    .font(.callout.weight(.medium))
            } else {
                Text(String(
                    format: String(localized: "No %1$@ match “%2$@”"),
                    containerNamePlural.lowercased(),
                    viewModel.searchText
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var createButton: some View {
        HStack {
            Button {
                dismiss()
                commands?.onRequestCreate()
            } label: {
                Label(String(format: String(localized: "New %@…"), containerName), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(format: String(localized: "New %@ (⌘N)"), containerName))
            .keyboardShortcut("n", modifiers: .command)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func commitSelection() {
        guard let name = viewModel.primarySelection else { return }
        onCommit(name)
    }

    private func refreshCreateSupport() async {
        guard commands != nil else { return }
        do {
            let spec = try await viewModel.loadCreateDatabaseForm()
            supportsCreateDatabase = spec != nil
        } catch {
            supportsCreateDatabase = false
        }
    }
}
