//
//  WelcomeViewModel.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

enum WelcomeActiveSheet: Identifiable {
    case newGroup
    case activation
    case importFile(URL)
    case exportConnections([DatabaseConnection])

    var id: String {
        switch self {
        case .newGroup: "newGroup"
        case .activation: "activation"
        case .importFile(let u): "importFile-\(u.absoluteString)"
        case .exportConnections: "exportConnections"
        }
    }
}

@MainActor @Observable
final class WelcomeViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WelcomeViewModel")

    private let storage = ConnectionStorage.shared
    private let groupStorage = GroupStorage.shared
    private let dbManager = DatabaseManager.shared

    // MARK: - State

    var connections: [DatabaseConnection] = []
    var searchText = ""
    var selectedConnectionIds: Set<UUID> = []
    var groups: [ConnectionGroup] = []
    var linkedConnections: [LinkedConnection] = []
    var showOnboarding = !AppSettingsStorage.shared.hasCompletedOnboarding()
    var connectionsToDelete: [DatabaseConnection] = []
    var showDeleteConfirmation = false
    var pendingMoveToNewGroup: [DatabaseConnection] = []
    var activeSheet: WelcomeActiveSheet?
    var pluginInstallConnection: DatabaseConnection?

    var renameGroupTarget: ConnectionGroup?
    var renameGroupName = ""
    var showRenameGroupAlert = false

    var collapsedGroupIds: Set<UUID> = {
        let strings = UserDefaults.standard.stringArray(forKey: "com.TablePro.collapsedGroupIds") ?? []
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }() {
        didSet {
            UserDefaults.standard.set(
                Array(collapsedGroupIds.map(\.uuidString)),
                forKey: "com.TablePro.collapsedGroupIds"
            )
        }
    }

    // MARK: - Notification Observers

    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var connectionUpdatedObserver: NSObjectProtocol?
    @ObservationIgnored private var shareFileObserver: NSObjectProtocol?
    @ObservationIgnored private var exportObserver: NSObjectProtocol?
    @ObservationIgnored private var importObserver: NSObjectProtocol?
    @ObservationIgnored private var linkedFoldersObserver: NSObjectProtocol?
    @ObservationIgnored private var newConnectionObserver: NSObjectProtocol?

    // MARK: - Computed Properties

    var filteredConnections: [DatabaseConnection] {
        if searchText.isEmpty {
            return connections
        }
        return connections.filter { connection in
            connection.name.localizedCaseInsensitiveContains(searchText)
                || connection.host.localizedCaseInsensitiveContains(searchText)
                || connection.database.localizedCaseInsensitiveContains(searchText)
                || groupName(for: connection.groupId)?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var ungroupedConnections: [DatabaseConnection] {
        let validGroupIds = Set(groups.map(\.id))
        return filteredConnections.filter { conn in
            guard let groupId = conn.groupId else { return true }
            return !validGroupIds.contains(groupId)
        }
    }

    var activeGroups: [ConnectionGroup] {
        let groupIds = Set(filteredConnections.compactMap(\.groupId))
        return groups.filter { groupIds.contains($0.id) }
    }

    var flatVisibleConnections: [DatabaseConnection] {
        var result = ungroupedConnections
        for group in activeGroups where !collapsedGroupIds.contains(group.id) {
            result.append(contentsOf: connections(in: group))
        }
        return result
    }

    var selectedConnections: [DatabaseConnection] {
        connections.filter { selectedConnectionIds.contains($0.id) }
    }

    var isMultipleSelection: Bool {
        selectedConnectionIds.count > 1
    }

    func groupName(for groupId: UUID?) -> String? {
        guard let groupId else { return nil }
        return groups.first { $0.id == groupId }?.name
    }

    func connections(in group: ConnectionGroup) -> [DatabaseConnection] {
        filteredConnections.filter { $0.groupId == group.id }
    }

    // MARK: - Setup & Teardown

    func setUp(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        guard connectionUpdatedObserver == nil else { return }

        newConnectionObserver = NotificationCenter.default.addObserver(
            forName: .newConnection, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openWindow?(id: "connection-form", value: nil as UUID?)
            }
        }

        connectionUpdatedObserver = NotificationCenter.default.addObserver(
            forName: .connectionUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadConnections()
            }
        }

        shareFileObserver = NotificationCenter.default.addObserver(
            forName: .connectionShareFileOpened, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let url = notification.object as? URL else { return }
                self?.activeSheet = .importFile(url)
            }
        }

        exportObserver = NotificationCenter.default.addObserver(
            forName: .exportConnections, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.connections.isEmpty else { return }
                self.activeSheet = .exportConnections(self.connections)
            }
        }

        importObserver = NotificationCenter.default.addObserver(
            forName: .importConnections, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.importConnectionsFromFile()
            }
        }

        linkedFoldersObserver = NotificationCenter.default.addObserver(
            forName: .linkedFoldersDidUpdate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.linkedConnections = LinkedFolderWatcher.shared.linkedConnections
            }
        }

        loadConnections()
        linkedConnections = LinkedFolderWatcher.shared.linkedConnections
    }

    deinit {
        [connectionUpdatedObserver, shareFileObserver, exportObserver,
         importObserver, linkedFoldersObserver, newConnectionObserver].forEach {
            if let observer = $0 {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    // MARK: - Data Loading

    func loadConnections() {
        connections = storage.loadConnections()
        loadGroups()
    }

    func loadGroups() {
        groups = groupStorage.loadGroups()
    }

    // MARK: - Connection Actions

    func connectToDatabase(_ connection: DatabaseConnection) {
        guard let openWindow else { return }
        WindowOpener.shared.pendingConnectionId = connection.id
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                if case PluginError.pluginNotInstalled = error {
                    Self.logger.info("Plugin not installed for \(connection.type.rawValue), prompting install")
                    handleMissingPlugin(connection: connection)
                } else {
                    Self.logger.error(
                        "Failed to connect: \(error.localizedDescription, privacy: .public)")
                    handleConnectionFailure(error: error)
                }
            }
        }
    }

    func connectAfterInstall(_ connection: DatabaseConnection) {
        guard let openWindow else { return }
        WindowOpener.shared.pendingConnectionId = connection.id
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                Self.logger.error(
                    "Failed to connect after plugin install: \(error.localizedDescription, privacy: .public)")
                handleConnectionFailure(error: error)
            }
        }
    }

    func connectSelectedConnections() {
        for connection in selectedConnections {
            connectToDatabase(connection)
        }
    }

    func connectToLinkedConnection(_ linked: LinkedConnection) {
        let connection = DatabaseConnection(
            id: linked.id,
            name: linked.connection.name,
            host: linked.connection.host,
            port: linked.connection.port,
            database: linked.connection.database,
            username: linked.connection.username,
            type: DatabaseType(rawValue: linked.connection.type)
        )
        connectToDatabase(connection)
    }

    func duplicateConnection(_ connection: DatabaseConnection) {
        let duplicate = storage.duplicateConnection(connection)
        loadConnections()
        openWindow?(id: "connection-form", value: duplicate.id as UUID?)
        focusConnectionFormWindow()
    }

    // MARK: - Delete

    func deleteSelectedConnections() {
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        storage.deleteConnections(connectionsToDelete)
        connections.removeAll { idsToDelete.contains($0.id) }
        selectedConnectionIds.subtract(idsToDelete)
        connectionsToDelete = []
    }

    // MARK: - Groups

    func deleteGroup(_ group: ConnectionGroup) {
        for i in connections.indices where connections[i].groupId == group.id {
            connections[i].groupId = nil
        }
        storage.saveConnections(connections)
        groupStorage.deleteGroup(group)
        groups = groupStorage.loadGroups()
    }

    func beginRenameGroup(_ group: ConnectionGroup) {
        renameGroupTarget = group
        renameGroupName = group.name
        showRenameGroupAlert = true
    }

    func confirmRenameGroup() {
        guard let target = renameGroupTarget else { return }
        let newName = renameGroupName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let isDuplicate = groups.contains {
            $0.id != target.id && $0.name.lowercased() == newName.lowercased()
        }
        guard !isDuplicate else { return }
        var updated = target
        updated.name = newName
        groupStorage.updateGroup(updated)
        groups = groupStorage.loadGroups()
        renameGroupTarget = nil
    }

    func updateGroupColor(_ group: ConnectionGroup, color: ConnectionColor) {
        var updated = group
        updated.color = color
        groupStorage.updateGroup(updated)
        groups = groupStorage.loadGroups()
    }

    func moveConnections(_ targets: [DatabaseConnection], toGroup groupId: UUID) {
        let ids = Set(targets.map(\.id))
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = groupId
        }
        storage.saveConnections(connections)
    }

    func removeFromGroup(_ targets: [DatabaseConnection]) {
        let ids = Set(targets.map(\.id))
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = nil
        }
        storage.saveConnections(connections)
    }

    // MARK: - Import / Export

    func exportConnections(_ connectionsToExport: [DatabaseConnection]) {
        activeSheet = .exportConnections(connectionsToExport)
    }

    func importConnectionsFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tableproConnectionShare]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        activeSheet = .importFile(url)
    }

    func showImportResultAlert(count: Int) {
        let alert = NSAlert()
        if count > 0 {
            alert.alertStyle = .informational
            alert.messageText = String(localized: "Import Complete")
            alert.informativeText = count == 1
                ? String(localized: "1 connection was imported.")
                : String(localized: "\(count) connections were imported.")
            alert.icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemGreen]))
        } else {
            alert.alertStyle = .informational
            alert.messageText = String(localized: "No Connections Imported")
            alert.informativeText = String(localized: "All selected connections were skipped.")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Keyboard Navigation

    func moveToNextConnection() {
        let visible = flatVisibleConnections
        guard !visible.isEmpty else { return }
        let anchorId = visible.last(where: { selectedConnectionIds.contains($0.id) })?.id
        guard let anchorId,
              let index = visible.firstIndex(where: { $0.id == anchorId }) else {
            selectedConnectionIds = Set([visible[0].id])
            return
        }
        let next = min(index + 1, visible.count - 1)
        selectedConnectionIds = [visible[next].id]
    }

    func moveToPreviousConnection() {
        let visible = flatVisibleConnections
        guard !visible.isEmpty else { return }
        let anchorId = visible.first(where: { selectedConnectionIds.contains($0.id) })?.id
        guard let anchorId,
              let index = visible.firstIndex(where: { $0.id == anchorId }) else {
            selectedConnectionIds = Set([visible[visible.count - 1].id])
            return
        }
        let prev = max(index - 1, 0)
        selectedConnectionIds = [visible[prev].id]
    }

    func collapseSelectedGroup() {
        guard let id = selectedConnectionIds.first,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              !collapsedGroupIds.contains(groupId) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedGroupIds.insert(groupId)
        }
    }

    func expandSelectedGroup() {
        guard let id = selectedConnectionIds.first,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              collapsedGroupIds.contains(groupId) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedGroupIds.remove(groupId)
        }
    }

    // MARK: - Reorder

    func moveUngroupedConnections(from source: IndexSet, to destination: Int) {
        let validGroupIds = Set(groups.map(\.id))
        let ungroupedIndices = connections.indices.filter { index in
            guard let groupId = connections[index].groupId else { return true }
            return !validGroupIds.contains(groupId)
        }

        guard source.allSatisfy({ $0 < ungroupedIndices.count }),
              destination <= ungroupedIndices.count else { return }

        let globalSource = IndexSet(source.map { ungroupedIndices[$0] })
        let globalDestination: Int
        if destination < ungroupedIndices.count {
            globalDestination = ungroupedIndices[destination]
        } else if let last = ungroupedIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        connections.move(fromOffsets: globalSource, toOffset: globalDestination)
        storage.saveConnections(connections)
    }

    func moveGroupedConnections(in group: ConnectionGroup, from source: IndexSet, to destination: Int) {
        let groupIndices = connections.indices.filter { connections[$0].groupId == group.id }

        guard source.allSatisfy({ $0 < groupIndices.count }),
              destination <= groupIndices.count else { return }

        let globalSource = IndexSet(source.map { groupIndices[$0] })
        let globalDestination: Int
        if destination < groupIndices.count {
            globalDestination = groupIndices[destination]
        } else if let last = groupIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        connections.move(fromOffsets: globalSource, toOffset: globalDestination)
        storage.saveConnections(connections)
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        let active = activeGroups
        let activeGroupIndices = active.compactMap { activeGroup in
            groups.firstIndex(where: { $0.id == activeGroup.id })
        }

        guard source.allSatisfy({ $0 < activeGroupIndices.count }),
              destination <= activeGroupIndices.count else { return }

        let globalSource = IndexSet(source.map { activeGroupIndices[$0] })
        let globalDestination: Int
        if destination < activeGroupIndices.count {
            globalDestination = activeGroupIndices[destination]
        } else if let last = activeGroupIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        groups.move(fromOffsets: globalSource, toOffset: globalDestination)
        groupStorage.saveGroups(groups)
    }

    func focusConnectionFormWindow() {
        Task { @MainActor in
            for _ in 0..<10 {
                for window in NSApp.windows where
                    window.identifier?.rawValue == "connection-form" {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    // MARK: - Private Helpers

    private func handleConnectionFailure(error: Error) {
        guard let openWindow else { return }
        NSApplication.shared.closeWindows(withId: "main")
        openWindow(id: "welcome")

        AlertHelper.showErrorSheet(
            title: String(localized: "Connection Failed"),
            message: error.localizedDescription,
            window: nil
        )
    }

    private func handleMissingPlugin(connection: DatabaseConnection) {
        guard let openWindow else { return }
        NSApplication.shared.closeWindows(withId: "main")
        openWindow(id: "welcome")
        pluginInstallConnection = connection
    }
}
