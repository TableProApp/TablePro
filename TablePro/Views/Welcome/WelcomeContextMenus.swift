//
//  WelcomeContextMenus.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

internal struct WelcomeNewConnectionMenu: View {
    let vm: WelcomeViewModel

    var body: some View {
        Button(action: { WindowOpener.shared.openConnectionForm() }) {
            Label("New Connection…", systemImage: "plus")
        }

        Divider()

        Button {
            vm.importConnectionsFromFile()
        } label: {
            Label(String(localized: "Import Connections…"), systemImage: "square.and.arrow.down")
        }

        Button {
            vm.importConnectionsFromApp()
        } label: {
            Label(String(localized: "Import from Other App…"), systemImage: "square.and.arrow.down.on.square")
        }
    }
}

extension WelcomeConnectionList {
    @ViewBuilder
    func contextMenuContent(for ids: Set<UUID>) -> some View {
        let connections = vm.connections.filter { ids.contains($0.id) }
        let external = vm.externalConnections(for: ids)
        switch WelcomeContextMenuKind.resolve(savedCount: connections.count, externalCount: external.count) {
        case .newConnection:
            WelcomeNewConnectionMenu(vm: vm)
        case .singleConnection:
            if let single = connections.first {
                singleConnectionContextMenu(for: single)
            }
        case .multipleConnections:
            multiSelectionContextMenu(
                for: connections,
                selection: ids,
                selectionCount: connections.count + external.count
            )
        case .externalOnly:
            externalConnectionContextMenu(for: external)
        }
    }

    @ViewBuilder
    private func externalConnectionContextMenu(for external: [LinkedConnection]) -> some View {
        if !external.isEmpty {
            Button { primaryAction(for: Set(external.map(\.id))) } label: {
                Label(
                    external.count == 1
                        ? String(localized: "Connect")
                        : String(format: String(localized: "Connect %d Connections"), external.count),
                    systemImage: "play.fill"
                )
            }

            if external.count == 1, let linked = external.first, vm.isLinkedFolderConnection(linked.id) {
                Divider()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([linked.sourceFileURL])
                } label: {
                    Label(String(localized: "Show in Finder"), systemImage: "folder")
                }
            }
        }
    }

    @ViewBuilder
    private func multiSelectionContextMenu(
        for connections: [DatabaseConnection],
        selection: Set<UUID>,
        selectionCount: Int
    ) -> some View {
        Button { primaryAction(for: selection) } label: {
            Label(
                String(format: String(localized: "Connect %d Connections"), selectionCount),
                systemImage: "play.fill"
            )
        }

        Divider()

        let allFavorited = connections.allSatisfy(\.isFavorite)
        Button { vm.toggleFavorite(connections) } label: {
            Label(
                allFavorited
                    ? String(localized: "Remove from Favorites")
                    : String(localized: "Add to Favorites"),
                systemImage: allFavorited ? "star.slash" : "star"
            )
        }

        Divider()

        Menu(String(localized: "Share")) {
            Button {
                vm.exportConnections(connections)
            } label: {
                Label(
                    String(format: String(localized: "Export %d Connections to File…"), connections.count),
                    systemImage: "square.and.arrow.up"
                )
            }

            if vm.services.licenseManager.isFeatureAvailable(.teamCatalog) {
                Button {
                    vm.publishToTeamCatalog(connections)
                } label: {
                    Label(
                        String(format: String(localized: "Publish %d Connections to Team Catalog…"), connections.count),
                        systemImage: "person.2.fill"
                    )
                }
            }

            if vm.services.licenseManager.isFeatureAvailable(.teamLibrary) {
                Button {
                    vm.publishConnectionsToTeamLibrary(connections)
                } label: {
                    Label(
                        String(format: String(localized: "Publish %d Connections to Team Library…"), connections.count),
                        systemImage: "books.vertical.fill"
                    )
                }
            }
        }

        Divider()

        moveToGroupMenu(for: connections)

        let validGroupIds = Set(vm.groups.map(\.id))
        if connections.contains(where: { $0.groupId.map { validGroupIds.contains($0) } ?? false }) {
            Button { vm.removeFromGroup(connections) } label: {
                Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
            }
        }

        if vm.services.appSettings.sync.enabled {
            Divider()

            let allLocalOnly = connections.allSatisfy(\.localOnly)
            Button {
                vm.setIncludedInSync(connections, included: allLocalOnly)
            } label: {
                Label(
                    allLocalOnly
                        ? String(localized: "Include in iCloud Sync")
                        : String(localized: "Exclude from iCloud Sync"),
                    systemImage: allLocalOnly ? "icloud" : "icloud.slash"
                )
            }
        }

        Divider()

        Button(role: .destructive) {
            vm.requestDeleteConnections(connections)
        } label: {
            Label(
                String(format: String(localized: "Delete %d Connections"), connections.count),
                systemImage: "trash"
            )
        }
    }

    @ViewBuilder
    private func singleConnectionContextMenu(for connection: DatabaseConnection) -> some View {
        Button { vm.connectToDatabase(connection) } label: {
            Label(String(localized: "Connect"), systemImage: "play.fill")
        }

        if ConnectionMenuPolicy.showsDisconnect(
            status: vm.services.databaseManager.session(for: connection.id)?.status ?? .disconnected
        ) {
            Button(role: .destructive) {
                Task {
                    await ConnectionDisconnectAction.disconnect(
                        connectionId: connection.id,
                        connectionName: connection.name,
                        presentingWindow: NSApp.keyWindow
                    )
                }
            } label: {
                Label(String(localized: "Disconnect"), systemImage: "cable.connector.slash")
            }
        }

        Divider()

        editConnectionButton(for: connection)

        Button { vm.duplicateConnection(connection) } label: {
            Label(String(localized: "Duplicate"), systemImage: "doc.on.doc")
        }

        Divider()

        Button { CompareSyncLauncher.open(prefillSource: connection.id) } label: {
            Label(String(localized: "Compare & Sync With…"), systemImage: "arrow.left.arrow.right.square")
        }

        Divider()

        Button { vm.toggleFavorite([connection]) } label: {
            Label(
                connection.isFavorite
                    ? String(localized: "Remove from Favorites")
                    : String(localized: "Add to Favorites"),
                systemImage: connection.isFavorite ? "star.slash" : "star"
            )
        }

        Divider()

        Menu(String(localized: "Share")) {
            Button {
                ClipboardService.shared.writeSecretText(vm.connectionString(for: connection))
            } label: {
                Label(String(localized: "Copy Connection String"), systemImage: "link")
            }

            Button {
                if let link = ConnectionExportService.buildImportDeeplink(for: connection) {
                    ClipboardService.shared.writeText(link)
                }
            } label: {
                Label(String(localized: "Copy TablePro Link"), systemImage: "link.badge.plus")
            }

            Button {
                let json = ConnectionExportService.buildCompactJSON(for: connection)
                ClipboardService.shared.writeText(json)
            } label: {
                Label(String(localized: "Copy as JSON"), systemImage: "doc.text")
            }

            Divider()

            Button {
                vm.exportConnections([connection])
            } label: {
                Label(String(localized: "Export to File…"), systemImage: "square.and.arrow.up")
            }

            if vm.services.licenseManager.isFeatureAvailable(.teamCatalog) {
                Button {
                    vm.publishToTeamCatalog([connection])
                } label: {
                    Label(String(localized: "Publish to Team Catalog…"), systemImage: "person.2.fill")
                }
            }

            if vm.services.licenseManager.isFeatureAvailable(.teamLibrary) {
                Button {
                    vm.publishConnectionsToTeamLibrary([connection])
                } label: {
                    Label(String(localized: "Publish to Team Library…"), systemImage: "books.vertical.fill")
                }
            }
        }

        Divider()

        moveToGroupMenu(for: [connection])

        if let groupId = connection.groupId, vm.groups.contains(where: { $0.id == groupId }) {
            Button { vm.removeFromGroup([connection]) } label: {
                Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
            }
        }

        if vm.services.appSettings.sync.enabled {
            Divider()

            Button {
                vm.setIncludedInSync([connection], included: connection.localOnly)
            } label: {
                Label(
                    connection.localOnly
                        ? String(localized: "Include in iCloud Sync")
                        : String(localized: "Exclude from iCloud Sync"),
                    systemImage: connection.localOnly ? "icloud" : "icloud.slash"
                )
            }
        }

        Divider()

        deleteConnectionButton(for: connection)
    }

    @ViewBuilder
    func editConnectionButton(for connection: DatabaseConnection) -> some View {
        Button {
            WindowOpener.shared.openConnectionForm(editing: connection.id)
        } label: {
            Label(String(localized: "Edit"), systemImage: "pencil")
        }
    }

    @ViewBuilder
    func deleteConnectionButton(for connection: DatabaseConnection) -> some View {
        Button(role: .destructive) {
            vm.requestDeleteConnections([connection])
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    @ViewBuilder
    func moveToGroupMenu(for targets: [DatabaseConnection]) -> some View {
        let isSingle = targets.count == 1
        let currentGroupId = isSingle ? targets.first?.groupId : nil
        let flatGroups = flattenGroupsForMenu(groups: vm.groups)
        Menu(String(localized: "Move to Group")) {
            ForEach(flatGroups, id: \.group.id) { entry in
                Button {
                    vm.moveConnections(targets, toGroup: entry.group.id)
                } label: {
                    HStack {
                        if !entry.group.color.isDefault {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(entry.group.color.color)
                        }
                        Text(String(repeating: "  ", count: entry.depth) + entry.group.name)
                        if currentGroupId == entry.group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(currentGroupId == entry.group.id)
            }

            if !vm.groups.isEmpty {
                Divider()
            }

            Button {
                vm.pendingMoveToNewGroup = targets
                vm.activeSheet = .newGroup(parentId: nil)
            } label: {
                Label(String(localized: "New Group…"), systemImage: "folder.badge.plus")
            }
        }
    }
}
