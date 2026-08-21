import AppKit
import SwiftUI
import TableProPluginKit

struct DatabaseSwitcherPopoverHost: View {
    weak var coordinator: MainContentCoordinator?
    /// Which container dimension this presentation switches. An engine can have both, so the caller
    /// names the one it opened rather than the popover guessing from the engine's primary target.
    var target: ContainerSwitchTarget?
    let dismiss: () -> Void

    var body: some View {
        if let coordinator {
            let connection = coordinator.connection
            let session = DatabaseManager.shared.session(for: connection.id)
            let switchTarget = target
                ?? PluginManager.shared.containerSwitchTarget(for: connection.type)
                ?? .database
            let activeContainer: String? = switch switchTarget {
            case .database: session?.browseDatabase ?? connection.database
            case .schema: coordinator.toolbarState.currentSchema ?? session?.browseSchema
            }

            DatabaseSwitcherPopover(
                currentDatabase: activeContainer,
                activeDatabase: session?.browseDatabase ?? connection.database,
                switchTarget: switchTarget,
                databaseType: connection.type,
                connectionId: connection.id,
                isReadOnly: coordinator.safeModeLevel.blocksAllWrites,
                onSelect: { [weak coordinator] container in
                    Task { await coordinator?.switchContainer(to: container, target: switchTarget) }
                },
                onRequestCreate: { [weak coordinator] in
                    coordinator?.activeSheet = .createDatabase
                },
                onRequestDrop: { [weak coordinator] containers in
                    coordinator?.requestContainerDrop(containers)
                },
                onRequestExport: { [weak coordinator] containers in
                    coordinator?.openExportDialog(containers: containers)
                },
                dismiss: dismiss
            )
        } else {
            EmptyView()
        }
    }
}

struct DatabaseSwitcherPopover: View {
    let currentDatabase: String?
    /// The database the rows belong to, which is the same thing as `currentDatabase` only when the
    /// popover is switching databases. In schema mode the rows are schemas inside this database.
    let activeDatabase: String
    let switchTarget: ContainerSwitchTarget
    let databaseType: DatabaseType
    let connectionId: UUID
    let isReadOnly: Bool
    let onSelect: (String) -> Void
    let onRequestCreate: () -> Void
    let onRequestDrop: ([DatabaseContainerRef]) -> Void
    let onRequestExport: ([DatabaseContainerRef]) -> Void

    /// An explicit closure rather than `@Environment(\.dismiss)`: the presenter owns the surface,
    /// and this content is hosted in an AppKit popover or panel that SwiftUI cannot dismiss.
    let dismiss: () -> Void
    @State private var viewModel: DatabaseSwitcherViewModel
    @State private var supportsCreateDatabase = false

    /// One declaration, read by this view's own frame and by whoever presents it, so the
    /// surface and its host can never disagree about how big it is.
    static let contentSize = NSSize(width: 320, height: 360)

    private var supportsDropDatabase: Bool {
        PluginManager.shared.supportsDropDatabase(for: databaseType)
    }
    private var supportsDropSchema: Bool {
        PluginManager.shared.supportsDropSchema(for: databaseType)
    }
    /// Creating is a database-only action here, so the row stays out of the schema list rather than
    /// offering "New Database" from a list of schemas.
    private var showsCreateRow: Bool {
        supportsCreateDatabase && switchTarget == .database
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

    init(
        currentDatabase: String?,
        activeDatabase: String,
        switchTarget: ContainerSwitchTarget,
        databaseType: DatabaseType,
        connectionId: UUID,
        isReadOnly: Bool,
        onSelect: @escaping (String) -> Void,
        onRequestCreate: @escaping () -> Void,
        onRequestDrop: @escaping ([DatabaseContainerRef]) -> Void,
        onRequestExport: @escaping ([DatabaseContainerRef]) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.currentDatabase = currentDatabase
        self.activeDatabase = activeDatabase
        self.switchTarget = switchTarget
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.isReadOnly = isReadOnly
        self.onSelect = onSelect
        self.onRequestCreate = onRequestCreate
        self.onRequestDrop = onRequestDrop
        self.onRequestExport = onRequestExport
        self.dismiss = dismiss
        self._viewModel = State(
            wrappedValue: DatabaseSwitcherViewModel(
                connectionId: connectionId,
                currentDatabase: currentDatabase,
                databaseType: databaseType,
                switchTarget: switchTarget,
                sidebarState: SharedSidebarState.forConnection(connectionId)
            ))
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
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(refreshShortcut)
        .task { await viewModel.fetchDatabases() }
        .task { await refreshCreateSupport() }
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

    /// The search field keeps focus for the whole flow, so the list is a presentation of that
    /// field's selection rather than a second focusable control. See `FieldDrivenList`.
    private var list: some View {
        FieldDrivenList(
            sections: [FieldDrivenListSection(id: "databases", items: viewModel.filteredDatabases)],
            selection: $viewModel.selectedDatabases,
            allowsMultipleSelection: true,
            onPrimaryAction: { name in
                viewModel.selectedDatabase = name
                commitSelection()
            },
            menuItems: { contextMenuItems(for: $0) },
            row: { row(for: $0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func contextMenuItems(for selection: Set<String>) -> [FieldDrivenMenuItem] {
        let targets = containerRefs(for: selection)
        let droppable = ContainerDropEligibility.droppable(targets, context: dropEligibilityContext)
        var items: [FieldDrivenMenuItem] = []

        if !targets.isEmpty {
            let copyTitle = targets.count == 1
                ? String(localized: "Copy Name")
                : String(format: String(localized: "Copy %lld Names"), targets.count)
            items.append(FieldDrivenMenuItem(title: copyTitle) {
                ClipboardService.shared.writeText(targets.map(\.name).joined(separator: ","))
            })
            /// The sidebar's menu has always asked whether the dialog can reach these containers
            /// before offering Export. This list offered it unconditionally, so the two menus for
            /// the same command could disagree.
            if ExportPreselection.canPreselect(
                containers: targets,
                activeDatabase: activeDatabase,
                canReachOtherDatabases: databaseType.supportsConnectionPooling
            ) {
                items.append(FieldDrivenMenuItem(title: String(localized: "Export…")) {
                    dismiss()
                    onRequestExport(targets)
                })
            }
        }

        if !droppable.isEmpty {
            items.append(.separator)
            items.append(FieldDrivenMenuItem(title: dropMenuTitle(for: droppable)) {
                dismiss()
                onRequestDrop(droppable)
            })
        }
        return items
    }

    /// A row's ref has to carry the kind the row actually is. Building a `.database` ref out of a
    /// schema name sends Drop to `dropDatabase` and gives Export a container it cannot resolve.
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

    private var dropEligibilityContext: ContainerDropEligibility.Context {
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
            Text(message)
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
                onRequestCreate()
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
        if name == currentDatabase {
            dismiss()
            return
        }
        onSelect(name)
        dismiss()
    }

    private func refreshCreateSupport() async {
        do {
            let spec = try await viewModel.loadCreateDatabaseForm()
            supportsCreateDatabase = spec != nil
        } catch {
            supportsCreateDatabase = false
        }
    }
}
