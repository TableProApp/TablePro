//
//  WelcomeContextMenus.swift
//  TablePro
//

import SwiftUI

extension WelcomeWindowView {
    @ViewBuilder
    func contextMenuContent(for connection: DatabaseConnection) -> some View {
        if vm.isMultipleSelection, vm.selectedConnectionIds.contains(connection.id) {
            Button { vm.connectSelectedConnections() } label: {
                Label(
                    String(localized: "Connect \(vm.selectedConnectionIds.count) Connections"),
                    systemImage: "play.fill"
                )
            }

            Divider()

            Button {
                vm.exportConnections(Array(vm.selectedConnections))
            } label: {
                Label(
                    String(localized: "Export \(vm.selectedConnectionIds.count) Connections..."),
                    systemImage: "square.and.arrow.up"
                )
            }

            Divider()

            moveToGroupMenu(for: vm.selectedConnections)

            let validGroupIds = Set(vm.groups.map(\.id))
            if vm.selectedConnections.contains(where: { $0.groupId.map { validGroupIds.contains($0) } ?? false }) {
                Button { vm.removeFromGroup(vm.selectedConnections) } label: {
                    Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
                }
            }

            Divider()

            Button(role: .destructive) {
                vm.connectionsToDelete = vm.selectedConnections
                vm.showDeleteConfirmation = true
            } label: {
                Label(
                    String(localized: "Delete \(vm.selectedConnectionIds.count) Connections"),
                    systemImage: "trash"
                )
            }
        } else {
            Button { vm.connectToDatabase(connection) } label: {
                Label(String(localized: "Connect"), systemImage: "play.fill")
            }

            Divider()

            Button {
                openWindow(id: "connection-form", value: connection.id as UUID?)
                vm.focusConnectionFormWindow()
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }

            Button { vm.duplicateConnection(connection) } label: {
                Label(String(localized: "Duplicate"), systemImage: "doc.on.doc")
            }

            Divider()

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
                Label(String(localized: "Copy as URL"), systemImage: "link")
            }

            Button {
                let link = ConnectionExportService.buildImportDeeplink(for: connection)
                ClipboardService.shared.writeText(link)
            } label: {
                Label(String(localized: "Copy as Import Link"), systemImage: "link.badge.plus")
            }

            Button {
                vm.exportConnections([connection])
            } label: {
                Label(String(localized: "Export..."), systemImage: "square.and.arrow.up")
            }

            Divider()

            moveToGroupMenu(for: [connection])

            if let groupId = connection.groupId, vm.groups.contains(where: { $0.id == groupId }) {
                Button { vm.removeFromGroup([connection]) } label: {
                    Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
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
    }

    @ViewBuilder
    func moveToGroupMenu(for targets: [DatabaseConnection]) -> some View {
        let isSingle = targets.count == 1
        let currentGroupId = isSingle ? targets.first?.groupId : nil
        Menu(String(localized: "Move to Group")) {
            ForEach(vm.groups) { group in
                Button {
                    vm.moveConnections(targets, toGroup: group.id)
                } label: {
                    HStack {
                        if !group.color.isDefault {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(group.color.color)
                        }
                        Text(group.name)
                        if currentGroupId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(currentGroupId == group.id)
            }

            if !vm.groups.isEmpty {
                Divider()
            }

            Button {
                vm.pendingMoveToNewGroup = targets
                vm.activeSheet = .newGroup
            } label: {
                Label(String(localized: "New Group..."), systemImage: "folder.badge.plus")
            }
        }
    }

    @ViewBuilder
    var newConnectionContextMenu: some View {
        Button(action: { openWindow(id: "connection-form") }) {
            Label("New Connection...", systemImage: "plus")
        }

        Divider()

        Button {
            vm.importConnectionsFromFile()
        } label: {
            Label(String(localized: "Import Connections..."), systemImage: "square.and.arrow.down")
        }
    }
}
