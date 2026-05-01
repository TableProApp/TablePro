//
//  WelcomeContextMenus.swift
//  TablePro
//

import SwiftUI

extension WelcomeWindowView {
    @ViewBuilder
    func contextMenuContent(for connection: DatabaseConnection) -> some View {
        if vm.isMultipleSelection, vm.selectedConnectionIds.contains(connection.id) {
            multiSelectionContextMenu(for: connection)
        } else {
            singleConnectionContextMenu(for: connection)
        }
    }

    @ViewBuilder
    private func multiSelectionContextMenu(for connection: DatabaseConnection) -> some View {
        Button { vm.connectSelectedConnections() } label: {
            Label(
                String(format: String(localized: "Connect %d Connections"), vm.selectedConnectionIds.count),
                systemImage: "play.fill"
            )
        }

        Divider()

        Menu(String(localized: "Share")) {
            Button {
                vm.exportConnections(Array(vm.selectedConnections))
            } label: {
                Label(
                    String(format: String(localized: "Export %d Connections to File..."), vm.selectedConnectionIds.count),
                    systemImage: "square.and.arrow.up"
                )
            }
        }

        Divider()

        moveToGroupMenu(for: vm.selectedConnections)

        let validGroupIds = Set(vm.groups.map(\.id))
        if vm.selectedConnections.contains(where: { $0.groupId.map { validGroupIds.contains($0) } ?? false }) {
            Button { vm.removeFromGroup(vm.selectedConnections) } label: {
                Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
            }
        }

        if AppSettingsManager.shared.sync.enabled {
            Divider()

            let allLocalOnly = vm.selectedConnections.allSatisfy(\.localOnly)
            Button {
                for conn in vm.selectedConnections {
                    var updated = conn
                    updated.localOnly = !allLocalOnly
                    ConnectionStorage.shared.updateConnection(updated)
                }
                NotificationCenter.default.post(name: .connectionUpdated, object: nil)
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
            vm.connectionsToDelete = vm.selectedConnections
            vm.showDeleteConfirmation = true
        } label: {
            Label(
                String(format: String(localized: "Delete %d Connections"), vm.selectedConnectionIds.count),
                systemImage: "trash"
            )
        }
    }

    @ViewBuilder
    private func singleConnectionContextMenu(for connection: DatabaseConnection) -> some View {
        Button { vm.connectToDatabase(connection) } label: {
            Label(String(localized: "Connect"), systemImage: "play.fill")
        }

        Divider()

        Button {
            ConnectionFormWindowFactory.openOrFront(connectionId: connection.id)
            vm.focusConnectionFormWindow()
        } label: {
            Label(String(localized: "Edit"), systemImage: "pencil")
        }

        Button { vm.duplicateConnection(connection) } label: {
            Label(String(localized: "Duplicate"), systemImage: "doc.on.doc")
        }

        Divider()

        Menu(String(localized: "Share")) {
            Button {
                let pw = ConnectionStorage.shared.loadPassword(for: connection.id)
                let sshPw: String?
                let sshProfile: SSHProfile?
                if let profileId = connection.sshProfileId {
                    sshPw = SSHProfileStorage.shared.loadSSHPassword(for: profileId)
                    sshProfile = SSHProfileStorage.shared.profile(for: profileId)
                } else {
                    sshPw = ConnectionStorage.shared.loadSSHPassword(for: connection.id)
                    sshProfile = nil
                }
                let url = ConnectionURLFormatter.format(
                    connection,
                    password: pw,
                    sshPassword: sshPw,
                    sshProfile: sshProfile
                )
                ClipboardService.shared.writeText(url)
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
                Label(String(localized: "Export to File..."), systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        moveToGroupMenu(for: [connection])

        if let groupId = connection.groupId, vm.groups.contains(where: { $0.id == groupId }) {
            Button { vm.removeFromGroup([connection]) } label: {
                Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
            }
        }

        if AppSettingsManager.shared.sync.enabled {
            Divider()

            Button {
                var updated = connection
                updated.localOnly.toggle()
                ConnectionStorage.shared.updateConnection(updated)
                NotificationCenter.default.post(name: .connectionUpdated, object: nil)
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

        Button(role: .destructive) {
            vm.connectionsToDelete = [connection]
            vm.showDeleteConfirmation = true
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
                Label(String(localized: "New Group..."), systemImage: "folder.badge.plus")
            }
        }
    }

    @ViewBuilder
    var newConnectionContextMenu: some View {
        Button(action: { ConnectionFormWindowFactory.openOrFront() }) {
            Label("New Connection...", systemImage: "plus")
        }

        Divider()

        Button {
            vm.importConnectionsFromFile()
        } label: {
            Label(String(localized: "Import Connections..."), systemImage: "square.and.arrow.down")
        }

        Button {
            vm.importConnectionsFromApp()
        } label: {
            Label(String(localized: "Import from Other App..."), systemImage: "square.and.arrow.down.on.square")
        }
    }
}

// MARK: - Flat Group Entry

struct FlatGroupEntry {
    let group: ConnectionGroup
    let depth: Int
}

func flattenGroupsForMenu(groups: [ConnectionGroup], parentId: UUID? = nil, depth: Int = 0) -> [FlatGroupEntry] {
    let validGroupIds = Set(groups.map(\.id))
    let levelGroups: [ConnectionGroup]
    if parentId == nil {
        levelGroups = groups
            .filter { $0.parentId == nil || ($0.parentId.flatMap { validGroupIds.contains($0) } != true) }
            .sorted {
                $0.sortOrder != $1.sortOrder
                    ? $0.sortOrder < $1.sortOrder
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    } else {
        levelGroups = groups
            .filter { $0.parentId == parentId }
            .sorted {
                $0.sortOrder != $1.sortOrder
                    ? $0.sortOrder < $1.sortOrder
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var result: [FlatGroupEntry] = []
    for group in levelGroups {
        result.append(FlatGroupEntry(group: group, depth: depth))
        result.append(contentsOf: flattenGroupsForMenu(groups: groups, parentId: group.id, depth: depth + 1))
    }
    return result
}
