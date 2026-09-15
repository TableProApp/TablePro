//
//  ConnectionTreeOutlineController+Menu.swift
//  TablePro
//

import AppKit

/// The connections tree's contextual menu, owned by the outline view.
///
/// `NSTableView`'s own secondary-click handling is what sets `clickedRow` and draws the clicked-row
/// highlight, so the menu hangs off the table and is filled in `menuNeedsUpdate`. Overriding
/// `menu(for:)` would lose both.
extension ConnectionTreeOutlineController: NSMenuDelegate {
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        SidebarMenuBuilder.fill(
            menu,
            with: ConnectionTreeMenuSpec.sections(for: menuContext()),
            target: self,
            action: #selector(performMenuCommand(_:))
        )
    }

    /// `clickedRow` is a display position, so the node is resolved through the outline view rather
    /// than by indexing anything. A right-click below the last row reports -1, which is the empty
    /// area and gets the background menu.
    private func clickedNode() -> ConnectionTreeNode? {
        guard outlineView.clickedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.clickedRow) as? ConnectionTreeNode
    }

    private func menuContext() -> ConnectionTreeMenuContext {
        let clicked = clickedNode()
        let connection = clicked?.connectionId.flatMap { connectionsById[$0] }
        return ConnectionTreeMenuContext(
            clicked: clicked?.kind,
            status: clicked?.status ?? .notConnected,
            connectionName: connection?.name ?? "",
            groups: GroupStorage.shared.loadGroups(),
            currentGroupId: connection?.groupId
        )
    }

    @objc
    internal func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarMenuCommandBox<ConnectionTreeMenuCommand>
        else { return }
        perform(box.command)
    }

    private func perform(_ command: ConnectionTreeMenuCommand) {
        switch command {
        case .connect(let id):
            autoExpansion.expect(id)
            host?.openConnectionInWindow(id)
        case .disconnect(let id):
            /// `userRequested`, not `appManaged`: the difference is what keeps a connection the
            /// user closed out of "Reopen Last Session".
            Task { await DatabaseManager.shared.disconnectSession(id, origin: .userRequested) }
        case .edit(let id):
            WindowOpener.shared.openConnectionForm(editing: id)
        case .duplicate(let id):
            duplicate(id)
        case .delete(let id):
            confirmDelete(id)
        case .copyConnectionString(let id):
            copyConnectionString(id)
        case let .moveToGroup(connectionId, groupId):
            move(connectionId, to: groupId)
        case .newConnection:
            WindowOpener.shared.openConnectionForm()
        case .deleteGroup(let group):
            confirmDeleteGroup(group)
        }
    }

    private func duplicate(_ id: UUID) {
        guard let connection = connectionsById[id] else { return }
        _ = ConnectionStorage.shared.duplicateConnection(connection)
        reload()
    }

    private func copyConnectionString(_ id: UUID) {
        guard let connection = connectionsById[id] else { return }
        /// No password and no SSH password. This lands on a clipboard, which every app on the
        /// machine can read, and a connection string is shared far more often than it is kept.
        let formatted = ConnectionURLFormatter.format(connection, password: nil, sshPassword: nil)
        ClipboardService.shared.writeText(formatted)
    }

    private func move(_ id: UUID, to groupId: UUID?) {
        guard var connection = connectionsById[id] else { return }
        connection.groupId = groupId
        ConnectionStorage.shared.updateConnection(connection)
        reload()
    }

    private func confirmDelete(_ id: UUID) {
        guard let connection = connectionsById[id] else { return }
        let window = view.window
        Task {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Delete “%@”?"), connection.name),
                message: String(localized: "Its saved password is deleted with it. This cannot be undone."),
                confirmButton: String(localized: "Delete"),
                window: window
            )
            guard confirmed else { return }
            _ = ConnectionStorage.shared.deleteConnection(connection)
            reload()
        }
    }

    /// Deleting a folder leaves its connections alone: `ConnectionTreeRootBuilder` shows a
    /// connection whose folder is gone at the top level, so nothing disappears with it.
    private func confirmDeleteGroup(_ group: ConnectionGroup) {
        let window = view.window
        Task {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Delete the group “%@”?"), group.name),
                message: String(localized: "The connections in it move back to the top level."),
                confirmButton: String(localized: "Delete"),
                window: window
            )
            guard confirmed else { return }
            GroupStorage.shared.deleteGroup(group)
            reload()
        }
    }
}
