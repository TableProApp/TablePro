//
//  WelcomeViewModel+Library.swift
//  TablePro
//

import AppKit
import Foundation
import TableProConnectionLibrary
import TableProImport

internal struct WelcomeResolvedRows: Equatable {
    internal var savedConnectionIds: [UUID] = []
    internal var sharedConnectionIds: [UUID] = []
    internal var groupIds: [UUID] = []
    internal var sections: Set<LibrarySectionKind> = []
    internal var hasSectionHeader = false
}

internal enum WelcomeDeleteIntent: Equatable {
    case connections([UUID])
    case group(UUID)
    case removeFavorites([UUID])
    case removeRecent([UUID])
}

internal struct WelcomeOrganizationState: Equatable {
    internal struct ConnectionPlacement: Equatable {
        internal let groupId: UUID?
        internal let sortOrder: Int
        internal let isFavorite: Bool
    }

    internal struct GroupPlacement: Equatable {
        internal let parentId: UUID?
        internal let sortOrder: Int
    }

    internal var connections: [UUID: ConnectionPlacement]
    internal var groups: [UUID: GroupPlacement]
    internal var favoritesOrder: [UUID]
}

extension WelcomeViewModel {
    // MARK: - Selection

    func resolve(_ rows: [LibraryRowID]) -> WelcomeResolvedRows {
        var resolved = WelcomeResolvedRows()
        var seenSaved: Set<UUID> = []
        var seenShared: Set<UUID> = []
        var seenGroups: Set<UUID> = []
        let shared = sharedConnectionsById
        for row in rows {
            switch row {
            case .section:
                resolved.hasSectionHeader = true
            case .group(let id):
                resolved.sections.insert(.connections)
                if groupsById[id] != nil, seenGroups.insert(id).inserted {
                    resolved.groupIds.append(id)
                }
            case .connection(let id, let section):
                resolved.sections.insert(section)
                if section.acceptsSavedConnections {
                    if connectionsById[id] != nil, seenSaved.insert(id).inserted {
                        resolved.savedConnectionIds.append(id)
                    }
                } else if shared[id] != nil, seenShared.insert(id).inserted {
                    resolved.sharedConnectionIds.append(id)
                }
            }
        }
        return resolved
    }

    func connect(rows: [LibraryRowID]) {
        let resolved = resolve(rows)
        for id in resolved.savedConnectionIds {
            guard let connection = connectionsById[id] else { continue }
            connectToDatabase(connection)
        }
        let shared = sharedConnectionsById
        for id in resolved.sharedConnectionIds {
            guard let linked = shared[id] else { continue }
            connectToLinkedConnection(linked)
        }
    }

    func deleteIntent(for rows: [LibraryRowID]) -> WelcomeDeleteIntent? {
        let resolved = resolve(rows)
        guard !resolved.hasSectionHeader,
              resolved.sharedConnectionIds.isEmpty,
              resolved.sections.count == 1,
              let section = resolved.sections.first else { return nil }
        switch section {
        case .favorites:
            return resolved.savedConnectionIds.isEmpty ? nil : .removeFavorites(resolved.savedConnectionIds)
        case .recent:
            return resolved.savedConnectionIds.isEmpty ? nil : .removeRecent(resolved.savedConnectionIds)
        case .connections:
            if !resolved.groupIds.isEmpty {
                guard resolved.savedConnectionIds.isEmpty, resolved.groupIds.count == 1,
                      let groupId = resolved.groupIds.first else { return nil }
                return .group(groupId)
            }
            return resolved.savedConnectionIds.isEmpty ? nil : .connections(resolved.savedConnectionIds)
        case .linkedFolders, .teamLibrary:
            return nil
        }
    }

    func performDelete(rows: [LibraryRowID]) {
        guard let intent = deleteIntent(for: rows) else { return }
        switch intent {
        case .connections(let ids):
            requestDeleteConnections(ids)
        case .group(let id):
            requestDeleteGroup(id)
        case .removeFavorites(let ids):
            setFavorite(ids, false, undoManager: outlineController?.outlineUndoManager)
        case .removeRecent(let ids):
            removeFromRecent(ids)
        }
    }

    func renamableRow(in rows: [LibraryRowID]) -> LibraryRowID? {
        guard rows.count == 1, let row = rows.first else { return nil }
        switch row {
        case .group(let id):
            return groupsById[id] == nil ? nil : row
        case .connection(let id, let section):
            return section.acceptsSavedConnections && connectionsById[id] != nil ? row : nil
        case .section:
            return nil
        }
    }

    func renameSelection() {
        guard let row = renamableRow(in: selection) else { return }
        outlineController?.beginRename(row)
    }

    func displayName(for row: LibraryRowID) -> String? {
        switch row {
        case .group(let id):
            return groupsById[id]?.name
        case .connection(let id, _):
            return connectionsById[id]?.name ?? sharedConnectionsById[id]?.connection.name
        case .section:
            return nil
        }
    }

    func commitRename(_ row: LibraryRowID, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != displayName(for: row) else { return }
        switch row {
        case .connection(let id, let section):
            guard section.acceptsSavedConnections else { return }
            if !storage.mutateConnections(ids: [id], { $0.name = name }) {
                reportLibraryWriteFailure()
            }
        case .group(let id):
            do {
                try groupStorage.mutateGroup(id: id) { $0.name = name }
            } catch {
                libraryErrorMessage = error.localizedDescription
            }
        case .section:
            return
        }
        loadConnections()
    }

    // MARK: - Mutations

    func toggleFavorite(_ ids: [UUID], undoManager: UndoManager?) {
        let makeFavorite = !ids.compactMap { connectionsById[$0] }.allSatisfy(\.isFavorite)
        setFavorite(ids, makeFavorite, undoManager: undoManager)
    }

    func setFavorite(_ ids: [UUID], _ isFavorite: Bool, before: UUID? = nil, undoManager: UndoManager?) {
        let actionName = isFavorite
            ? String(localized: "Add to Favorites")
            : String(localized: "Remove from Favorites")
        performUndoable(actionName, undoManager: undoManager) {
            applyFavorite(ids, isFavorite, before: before)
        }
    }

    private func applyFavorite(_ ids: [UUID], _ isFavorite: Bool, before: UUID?) {
        let targets = ids.filter { connectionsById[$0] != nil }
        guard !targets.isEmpty else { return }
        let displayed = LibraryOutlineBuilder.favoriteIds(outlineRequest(query: LibraryQuery()))
        guard storage.mutateConnections(ids: Set(targets), { $0.isFavorite = isFavorite }) else {
            reportLibraryWriteFailure()
            return
        }
        let order = isFavorite
            ? LibraryOrdering.favoritesOrder(displayed, inserting: targets, before: sortMode == .manual ? before : nil)
            : LibraryOrdering.favoritesOrder(displayed, removing: Set(targets))
        listPreferences.setFavoritesOrder(order)
    }

    func reorderFavorites(_ ids: [UUID], before: UUID?, undoManager: UndoManager?) {
        performUndoable(String(localized: "Reorder Favorites"), undoManager: undoManager) {
            let displayed = LibraryOutlineBuilder.favoriteIds(outlineRequest(query: LibraryQuery()))
            listPreferences.setFavoritesOrder(LibraryOrdering.favoritesOrder(displayed, inserting: ids, before: before))
        }
    }

    func removeFromRecent(_ ids: [UUID]) {
        recentConnections.remove(Set(ids))
        rebuildOutline()
    }

    func clearRecent() {
        recentConnections.clear()
        rebuildOutline()
    }

    func moveConnections(_ ids: [UUID], toGroup groupId: UUID?, before: UUID?, undoManager: UndoManager?) {
        performUndoable(String(localized: "Move Connections"), undoManager: undoManager) {
            guard storage.moveConnections(
                ids,
                toGroup: groupId,
                before: before,
                validGroupIds: Set(groups.map(\.id))
            ) else {
                reportLibraryWriteFailure()
                return
            }
            if let groupId {
                expandedGroupIds.formUnion(groupGraph.pathIds(to: groupId))
            }
        }
    }

    func moveGroups(_ ids: [UUID], toParent parentId: UUID?, before: UUID?, undoManager: UndoManager?) {
        performUndoable(String(localized: "Move Groups"), undoManager: undoManager) {
            do {
                try groupStorage.moveGroups(ids, toParent: parentId, before: before)
                if let parentId {
                    expandedGroupIds.formUnion(groupGraph.pathIds(to: parentId))
                }
            } catch {
                libraryErrorMessage = error.localizedDescription
            }
        }
    }

    func setGroupColor(_ groupId: UUID, _ color: ConnectionColor) {
        do {
            try groupStorage.mutateGroup(id: groupId) { $0.color = color }
        } catch {
            libraryErrorMessage = error.localizedDescription
        }
        loadConnections()
    }

    func setIncludedInSync(_ ids: [UUID], included: Bool) {
        if !storage.mutateConnections(ids: Set(ids), { $0.localOnly = !included }) {
            reportLibraryWriteFailure()
        }
        loadConnections()
    }

    func duplicateConnection(_ id: UUID) {
        guard let connection = connectionsById[id] else { return }
        guard let duplicate = storage.duplicateConnection(connection) else {
            reportLibraryWriteFailure()
            return
        }
        loadConnections()
        WindowOpener.shared.openConnectionForm(editing: duplicate.id)
    }

    func applyDrop(_ operation: LibraryDropOperation, undoManager: UndoManager?) {
        switch operation {
        case .moveConnections(let ids, let groupId, let before):
            moveConnections(ids, toGroup: groupId, before: before, undoManager: undoManager)
        case .moveGroups(let ids, let parentId, let before):
            moveGroups(ids, toParent: parentId, before: before, undoManager: undoManager)
        case .addFavorites(let ids, let before):
            setFavorite(ids, true, before: before, undoManager: undoManager)
        case .reorderFavorites(let ids, let before):
            reorderFavorites(ids, before: before, undoManager: undoManager)
        }
    }

    // MARK: - Undo

    func performUndoable(_ actionName: String, undoManager: UndoManager?, _ change: () -> Void) {
        let before = captureOrganizationState()
        change()
        loadConnections()
        guard let undoManager else { return }
        guard captureOrganizationState() != before else { return }
        registerRestore(to: before, actionName: actionName, undoManager: undoManager)
    }

    func captureOrganizationState() -> WelcomeOrganizationState {
        let storedConnections = storage.loadConnections()
        let storedGroups = groupStorage.loadGroups()
        return WelcomeOrganizationState(
            connections: Dictionary(
                storedConnections.map {
                    ($0.id, WelcomeOrganizationState.ConnectionPlacement(
                        groupId: $0.groupId,
                        sortOrder: $0.sortOrder,
                        isFavorite: $0.isFavorite
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            groups: Dictionary(
                storedGroups.map {
                    ($0.id, WelcomeOrganizationState.GroupPlacement(parentId: $0.parentId, sortOrder: $0.sortOrder))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            favoritesOrder: listPreferences.favoritesOrder
        )
    }

    func restoreOrganizationState(_ target: WelcomeOrganizationState) {
        let current = captureOrganizationState()
        let changedConnections = target.connections.filter { id, placement in
            guard let now = current.connections[id] else { return false }
            return now != placement
        }
        if !storage.mutateConnections(ids: Set(changedConnections.keys), { connection in
            guard let placement = changedConnections[connection.id] else { return }
            connection.groupId = placement.groupId
            connection.sortOrder = placement.sortOrder
            connection.isFavorite = placement.isFavorite
        }) {
            reportLibraryWriteFailure()
        }

        var pendingGroups = target.groups.filter { id, placement in
            guard let now = current.groups[id] else { return false }
            return now != placement
        }
        for _ in 0..<max(1, pendingGroups.count) where !pendingGroups.isEmpty {
            for (id, placement) in pendingGroups {
                do {
                    try groupStorage.mutateGroup(id: id) { group in
                        group.parentId = placement.parentId
                        group.sortOrder = placement.sortOrder
                    }
                    pendingGroups.removeValue(forKey: id)
                } catch {
                    continue
                }
            }
        }

        listPreferences.setFavoritesOrder(target.favoritesOrder)
        loadConnections()
    }

    private func registerRestore(to target: WelcomeOrganizationState, actionName: String, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { viewModel in
            let current = viewModel.captureOrganizationState()
            viewModel.restoreOrganizationState(target)
            viewModel.registerRestore(to: current, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Menu

    func menuContext(for rows: [LibraryRowID]) -> WelcomeMenuContext {
        let resolved = resolve(rows)
        let disconnectable = Set(resolved.savedConnectionIds.filter { id in
            ConnectionMenuPolicy.showsDisconnect(
                status: services.databaseManager.session(for: id)?.status ?? .disconnected
            )
        })
        return WelcomeMenuContext(
            rows: rows,
            resolved: resolved,
            connections: connectionsById,
            groups: groups,
            linkedFolderConnectionIds: Set(presentableLinkedConnections.map(\.id)),
            disconnectableConnectionIds: disconnectable,
            isSyncEnabled: services.appSettings.sync.enabled,
            canPublishToTeamCatalog: services.licenseManager.isFeatureAvailable(.teamCatalog),
            canPublishToTeamLibrary: services.licenseManager.isFeatureAvailable(.teamLibrary)
        )
    }

    func perform(_ command: WelcomeMenuCommand) {
        let undoManager = outlineController?.outlineUndoManager
        switch command {
        case .connect(let rows):
            connect(rows: rows)
        case .disconnect(let id):
            let name = connectionsById[id]?.name ?? ""
            Task {
                await ConnectionDisconnectAction.disconnect(
                    connectionId: id,
                    connectionName: name,
                    presentingWindow: NSApp.keyWindow
                )
            }
        case .edit(let id):
            WindowOpener.shared.openConnectionForm(editing: id)
        case .rename(let row):
            outlineController?.beginRename(row)
        case .duplicate(let id):
            duplicateConnection(id)
        case .compareAndSync(let id):
            CompareSyncLauncher.open(prefillSource: id)
        case .setFavorite(let ids, let isFavorite):
            setFavorite(ids, isFavorite, undoManager: undoManager)
        case .copyConnectionString(let id):
            guard let connection = connectionsById[id] else { return }
            ClipboardService.shared.writeSecretText(connectionString(for: connection))
        case .copyTableProLink(let id):
            guard let connection = connectionsById[id],
                  let link = ConnectionExportService.buildImportDeeplink(for: connection) else { return }
            ClipboardService.shared.writeText(link)
        case .copyJSON(let id):
            guard let connection = connectionsById[id] else { return }
            ClipboardService.shared.writeText(ConnectionExportService.buildCompactJSON(for: connection))
        case .exportToFile(let ids):
            exportConnections(ids.compactMap { connectionsById[$0] })
        case .publishToTeamCatalog(let ids):
            publishToTeamCatalog(ids.compactMap { connectionsById[$0] })
        case .publishToTeamLibrary(let ids):
            publishConnectionsToTeamLibrary(ids.compactMap { connectionsById[$0] })
        case .moveToGroup(let ids, let groupId):
            moveConnections(ids, toGroup: groupId, before: nil, undoManager: undoManager)
        case .moveToNewGroup(let ids):
            requestNewGroup(parentId: nil, movingConnectionIds: ids)
        case .setIncludedInSync(let ids, let included):
            setIncludedInSync(ids, included: included)
        case .deleteConnections(let ids):
            requestDeleteConnections(ids)
        case .removeFromRecent(let ids):
            removeFromRecent(ids)
        case .clearRecent:
            clearRecent()
        case .showInFinder(let id):
            guard let linked = linkedConnections.first(where: { $0.id == id }) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([linked.sourceFileURL])
        case .newSubgroup(let parentId):
            requestNewGroup(parentId: parentId, movingConnectionIds: [])
        case .setGroupColor(let id, let color):
            setGroupColor(id, color)
        case .moveGroup(let id, let parentId):
            moveGroups([id], toParent: parentId, before: nil, undoManager: undoManager)
        case .deleteGroup(let id):
            requestDeleteGroup(id)
        case .newConnection:
            WindowOpener.shared.openConnectionForm()
        case .newGroup:
            requestNewGroup(parentId: nil, movingConnectionIds: [])
        case .importConnections:
            importConnectionsFromFile()
        case .importFromURL:
            urlImportPresented = true
        case .importFromApp:
            importConnectionsFromApp()
        case .importFromAWS:
            importConnectionsFromAWS()
        case .openProjectFolder:
            openProjectFolder()
        }
    }
}
