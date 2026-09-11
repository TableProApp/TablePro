//
//  WelcomePresentations.swift
//  TablePro
//

import SwiftUI
import TableProImport
import UniformTypeIdentifiers

internal struct WelcomePresentations: ViewModifier {
    @Bindable var vm: WelcomeViewModel
    let onSheetDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(WelcomeDeletionAlerts(vm: vm))
            .sheet(item: $vm.activeSheet, onDismiss: {
                if let count = vm.pendingImportResultCount {
                    vm.importResultCount = count
                    vm.pendingImportResultCount = nil
                }
                onSheetDismiss()
                WindowOpener.shared.openStagedConnectionForm()
            }) { sheet in
                activeSheetContent(sheet)
            }
            .modifier(WelcomeConnectionCreationOverlays(vm: vm))
            .pluginInstallPromptForType(type: $vm.pendingInstallType) { type in
                vm.completePendingInstall(for: type)
            }
            .pluginInstallPrompt(connection: $vm.pluginInstallConnection) { connection in
                vm.connectAfterInstall(connection)
            }
            .sheet(item: $vm.pluginDiagnostic) { item in
                PluginDiagnosticSheet(item: item) {
                    vm.pluginDiagnostic = nil
                }
            }
            .modifier(WelcomeGroupAlerts(vm: vm))
            .alert(
                String(localized: "Connection Failed"),
                isPresented: $vm.showConnectionError
            ) {
                Button(String(localized: "OK"), role: .cancel) {
                    vm.connectionError = nil
                }
            } message: {
                if let error = vm.connectionError {
                    Text(error)
                }
            }
            .fileImporter(
                isPresented: $vm.showImportFilePanel,
                allowedContentTypes: [.tableproConnectionShare],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    vm.activeSheet = .importFile(url)
                }
            }
            .modifier(WelcomeImportResultAlert(vm: vm))
    }

    @ViewBuilder
    private func activeSheetContent(_ sheet: WelcomeActiveSheet) -> some View {
        switch sheet {
        case .newGroup(let parentId):
            CreateGroupSheet(parentId: parentId) { name, color, pid in
                try vm.createGroup(name: name, color: color, parentId: pid)
            }
        case .activation:
            LicenseActivationSheet()
        case .importFile(let url):
            ConnectionImportSheet(fileURL: url) { count in
                vm.pendingImportResultCount = count
                vm.activeSheet = nil
            }
        case .exportConnections(let conns):
            ConnectionExportOptionsSheet(connections: conns)
        case .importFromApp:
            ImportFromAppSheet { count in
                vm.pendingImportResultCount = count
                vm.activeSheet = nil
            }
        case .projectFolderScan(let url):
            ProjectFolderScanSheet(
                rootURL: url,
                onSelect: { parsed in
                    vm.activeSheet = nil
                    WindowOpener.shared.stageConnectionFormDraft(parsedURL: parsed)
                },
                onChooseAnotherFolder: {
                    vm.activeSheet = nil
                    vm.openProjectFolder()
                }
            )
        case .deeplinkImport(let exportable):
            DeeplinkImportSheet(connection: exportable) {
                vm.loadConnections()
            }
        }
    }
}

private struct WelcomeDeletionAlerts: ViewModifier {
    @Bindable var vm: WelcomeViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                vm.connectionsToDelete.count == 1
                    ? String(localized: "Delete Connection")
                    : String(format: String(localized: "Delete %d Connections"), vm.connectionsToDelete.count),
                isPresented: $vm.showDeleteConfirmation
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    vm.deleteSelectedConnections()
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    vm.connectionsToDelete = []
                }
            } message: {
                deletionMessage
            }
    }

    @ViewBuilder
    private var deletionMessage: some View {
        if vm.connectionsToDelete.count == 1, let first = vm.connectionsToDelete.first {
            if vm.pendingDeleteHasFavorites {
                Text("Are you sure you want to delete \"\(first.name)\"? Saved queries linked to this connection will also be deleted.")
            } else {
                Text("Are you sure you want to delete \"\(first.name)\"?")
            }
        } else if vm.pendingDeleteHasFavorites {
            Text("Are you sure you want to delete \(vm.connectionsToDelete.count) connections? Saved queries linked to these connections will also be deleted. This cannot be undone.")
        } else {
            Text("Are you sure you want to delete \(vm.connectionsToDelete.count) connections? This cannot be undone.")
        }
    }
}

private struct WelcomeGroupAlerts: ViewModifier {
    @Bindable var vm: WelcomeViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Delete Group"),
                isPresented: $vm.showDeleteGroupConfirmation
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    vm.confirmDeleteGroup()
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    vm.groupToDelete = nil
                }
            } message: {
                if let group = vm.groupToDelete {
                    Text("Are you sure you want to delete the group \"\(group.name)\"? Connections in this group will be moved to the top level.")
                }
            }
            .alert(String(localized: "Rename Group"), isPresented: $vm.showRenameGroupAlert) {
                TextField(String(localized: "Group name"), text: $vm.renameGroupName)
                Button(String(localized: "Rename")) { vm.confirmRenameGroup() }
                Button(String(localized: "Cancel"), role: .cancel) { vm.renameGroupTarget = nil }
            } message: {
                Text("Enter a new name for the group.")
            }
            .alert(
                String(localized: "Group Not Updated"),
                isPresented: Binding(
                    get: { vm.groupErrorMessage != nil },
                    set: { if !$0 { vm.groupErrorMessage = nil } }
                )
            ) {
                Button(String(localized: "OK")) { vm.groupErrorMessage = nil }
            } message: {
                if let message = vm.groupErrorMessage {
                    Text(message)
                }
            }
    }
}

private struct WelcomeImportResultAlert: ViewModifier {
    @Bindable var vm: WelcomeViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                (vm.importResultCount ?? 0) > 0
                    ? String(localized: "Import Complete")
                    : String(localized: "No Connections Imported"),
                isPresented: Binding(
                    get: { vm.importResultCount != nil },
                    set: { if !$0 { vm.importResultCount = nil } }
                )
            ) {
                Button(String(localized: "OK")) { vm.importResultCount = nil }
            } message: {
                if let count = vm.importResultCount, count > 0 {
                    Text(count == 1
                        ? String(localized: "1 connection was imported.")
                        : String(format: String(localized: "%d connections were imported."), count))
                } else {
                    Text(String(localized: "All selected connections were skipped."))
                }
            }
    }
}

private struct WelcomeConnectionCreationOverlays: ViewModifier {
    @Bindable var vm: WelcomeViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $vm.databaseTypeChooser, onDismiss: {
                WindowOpener.shared.openStagedConnectionForm()
            }) { payload in
                DatabaseTypeChooserSheet(
                    initialType: payload.initialType,
                    onSelected: { type in
                        vm.selectDatabaseType(type, for: payload)
                    },
                    onImportFromURL: { vm.presentURLImport() },
                    onCancel: { vm.databaseTypeChooser = nil }
                )
            }
            .sheet(isPresented: $vm.urlImportPresented, onDismiss: {
                WindowOpener.shared.openStagedConnectionForm()
            }) {
                ImportFromURLSheet(
                    onImported: { parsed in
                        vm.urlImportPresented = false
                        WindowOpener.shared.stageConnectionFormDraft(parsedURL: parsed)
                    },
                    onCancel: {
                        vm.urlImportPresented = false
                    }
                )
            }
    }
}
