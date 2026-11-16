import AppKit
import SwiftUI
import TableProPluginKit

struct DatabaseSwitcherPopoverHost: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    weak var coordinator: MainContentCoordinator?
    // An engine can switch both dimensions, so the caller names the one it opened.
    var target: ContainerSwitchTarget?
    let dismiss: () -> Void

    var body: some View {
        if let coordinator {
            let connection = coordinator.connection
            let session = databaseManager.session(for: connection.id)
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
                commands: DatabaseSwitcherList.ContainerCommands(
                    isReadOnly: coordinator.safeModeLevel.blocksAllWrites,
                    schemaEditEligibility: coordinator.schemaEditContext,
                    onRequestCreate: { [weak coordinator] in
                        switch switchTarget {
                        case .database: coordinator?.activeSheet = .createDatabase
                        case .schema: coordinator?.createSchema(database: nil)
                        }
                    },
                    onRequestDrop: { [weak coordinator] containers in
                        coordinator?.requestContainerDrop(containers)
                    },
                    onRequestExport: { [weak coordinator] containers in
                        coordinator?.openExportDialog(containers: containers)
                    },
                    onRequestEdit: { [weak coordinator] container in
                        coordinator?.editSchema(container)
                    }
                ),
                onSelect: { [weak coordinator] container in
                    Task { await coordinator?.switchContainer(to: container, target: switchTarget) }
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
    let activeDatabase: String
    let databaseType: DatabaseType
    let connectionId: UUID
    let commands: DatabaseSwitcherList.ContainerCommands
    let onSelect: (String) -> Void
    // AppKit hosts this content in a popover or panel that SwiftUI's dismiss cannot close.
    let dismiss: () -> Void
    @StateObject private var viewModel: DatabaseSwitcherViewModel

    // Read by this view's frame and by the presenter, so the two never disagree on size.
    static let contentSize = NSSize(width: 320, height: 360)

    init(
        currentDatabase: String?,
        activeDatabase: String,
        switchTarget: ContainerSwitchTarget,
        databaseType: DatabaseType,
        connectionId: UUID,
        commands: DatabaseSwitcherList.ContainerCommands,
        onSelect: @escaping (String) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.currentDatabase = currentDatabase
        self.activeDatabase = activeDatabase
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.commands = commands
        self.onSelect = onSelect
        self.dismiss = dismiss
        self._viewModel = StateObject(
            wrappedValue: DatabaseSwitcherViewModel(
                connectionId: connectionId,
                currentDatabase: currentDatabase,
                databaseType: databaseType,
                switchTarget: switchTarget,
                activeDatabase: activeDatabase,
                sidebarState: SharedSidebarState.forConnection(connectionId)
            ))
    }

    var body: some View {
        DatabaseSwitcherList(
            viewModel: viewModel,
            currentDatabase: currentDatabase,
            activeDatabase: activeDatabase,
            databaseType: databaseType,
            connectionId: connectionId,
            commands: commands,
            onCommit: { name in
                if name != currentDatabase {
                    onSelect(name)
                }
                dismiss()
            },
            dismiss: dismiss
        )
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }
}
