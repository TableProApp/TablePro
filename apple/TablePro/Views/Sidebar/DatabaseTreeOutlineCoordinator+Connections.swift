//
//  DatabaseTreeOutlineCoordinator+Connections.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProConnectionLibrary

/// The saved connections the tree lists above its own connection's databases: their rows, which of
/// them are open, and what a click, Return or the menu does on one.
///
/// The data, the commands and the menu are the connections column's own (`ConnectionNavigatorModel`,
/// `ConnectionNavigatorMenu`), so opening a connection from either list takes the same route and
/// never hosts a connection twice.
extension DatabaseTreeOutlineCoordinator {
    // MARK: - Model

    /// Starts listening the first time the tree lists the connections and stops when it no longer
    /// does, so a tree that never lists them reads no library and observes no event.
    internal func syncConnectionsModel() {
        guard listsConnections else {
            guard !connectionsModelObservations.isEmpty else { return }
            connectionsModelObservations.removeAll()
            connectionsModel?.stop()
            return
        }
        let model = connectionsModel ?? ConnectionNavigatorModel()
        connectionsModel = model
        // The window sets itself on the coordinator once it appears, which can be after the first reload.
        if model.host == nil {
            model.host = mainCoordinator?.splitViewController
        }
        guard connectionsModelObservations.isEmpty else { return }
        model.onOpenFailure = { [weak self] error in
            AlertHelper.showErrorSheet(
                title: String(localized: "Connection Failed"),
                message: error.localizedDescription,
                window: self?.outlineView?.window
            )
        }
        model.start()
        /// Subscribed after the first build, which this reload already draws. The model writes its
        /// rows before it moves either revision, so a sink reads the new rows.
        connectionsModelObservations = [
            model.$revision.dropFirst().sink { [weak self] _ in
                self?.scheduleReconcile(forcing: true)
            },
            model.$presentationRevision.dropFirst().sink { [weak self] _ in
                self?.applyConnectionMarks()
            },
        ]
    }

    /// A status or a window moved, which changes how a row is marked and never which rows exist, so
    /// the rows are reconfigured in place rather than reloaded.
    private func applyConnectionMarks() {
        guard listsConnections, let model = connectionsModel else { return }
        func apply(_ rows: [ConnectionNavigatorRow]) {
            for row in rows {
                switch row {
                case .group(let group):
                    apply(group.children)
                case .connection(let connection):
                    guard let node = nodeCache[DatabaseTreeNode.savedConnectionId(connection.id)],
                          let ref = node.savedConnectionRef
                    else { continue }
                    node.kind = .savedConnection(DatabaseTreeSavedConnectionRef(row: connection, ownsTree: ref.ownsTree))
                }
            }
        }
        apply(model.rows)
        refreshVisibleRows()
    }

    // MARK: - Rows

    internal func connectionTreeRows() -> [ConnectionNavigatorRow] {
        let library = connectionsModel?.rows ?? []
        return DatabaseTreeConnectionRows.rows(
            from: library,
            ownId: connectionId,
            unsavedOwnRow: DatabaseTreeConnectionRows.contains(connectionId, in: library) ? nil : unsavedOwnRow(),
            filterText: searchText
        )
    }

    /// A connection opened from a file or a link is in no group and in no saved list, yet its
    /// databases still need the row they hang from.
    private func unsavedOwnRow() -> ConnectionNavigatorConnectionRow? {
        guard let connection = DatabaseManager.shared.session(for: connectionId)?.connection else { return nil }
        return ConnectionNavigatorConnectionRow(
            connection: connection,
            groupPath: [],
            isDriverRejected: false,
            status: ConnectionStatusResolver.status(for: connectionId),
            placement: .shownHere
        )
    }

    internal func connectionLevelNodes(_ rows: [ConnectionNavigatorRow]) -> [DatabaseTreeNode] {
        rows.map { row in
            switch row {
            case .group(let group):
                return node(id: DatabaseTreeNode.connectionGroupId(group.id), kind: .connectionGroup(group))
            case .connection(let connection):
                return node(
                    id: DatabaseTreeNode.savedConnectionId(connection.id),
                    kind: .savedConnection(DatabaseTreeSavedConnectionRef(
                        row: connection,
                        ownsTree: connection.id == connectionId
                    ))
                )
            }
        }
    }

    // MARK: - Expansion

    /// Opens the groups the user left open, the ones above this tree's own connection once, and the
    /// own connection's row unless the user closed it. A search opens every group it left, since
    /// each holds a match or the tree's own connection.
    ///
    /// Returns the own connection's row when it is open on screen, so the caller restores what
    /// hangs under it.
    internal func applyConnectionExpansion(under parent: DatabaseTreeNode?) -> DatabaseTreeNode? {
        guard let outlineView else { return nil }
        revealOwnConnectionIfNeeded()
        let searching = !searchText.isEmpty
        var ownConnection: DatabaseTreeNode?
        func walk(_ nodes: [DatabaseTreeNode]) {
            for node in nodes {
                switch node.kind {
                case .connectionGroup(let group):
                    let open = searching
                        || revealedConnectionGroupIds.contains(group.id)
                        || connectionsModel?.isGroupExpanded(group) == true
                    setExpanded(node, open)
                    if outlineView.isItemExpanded(node) { walk(resolvedChildren(of: node)) }
                case .savedConnection(let ref) where ref.ownsTree:
                    setExpanded(node, searching || (viewModel?.isOwnConnectionExpanded ?? true))
                    if outlineView.isItemExpanded(node) { ownConnection = node }
                default:
                    continue
                }
            }
        }
        walk(resolvedChildren(of: parent))
        return ownConnection
    }

    /// Once per tree, so a group the user closes over the connection stays closed. A filter is not
    /// a reveal: it opens its own groups and gives them back when it clears.
    private func revealOwnConnectionIfNeeded() {
        guard !hasRevealedOwnConnection, searchText.isEmpty else { return }
        let rows = resolvedChildren(of: nil).compactMap { node -> ConnectionNavigatorRow? in
            switch node.kind {
            case .connectionGroup(let group): return .group(group)
            case .savedConnection(let ref): return .connection(ref.row)
            default: return nil
            }
        }
        guard let groupIds = DatabaseTreeConnectionRows.groupIds(above: connectionId, in: rows) else { return }
        hasRevealedOwnConnection = true
        revealedConnectionGroupIds.formUnion(groupIds)
    }

    // MARK: - Interaction

    /// The connection a click switches the window to, if the selection change came from one.
    internal func connectionClickTarget(selected nodes: [DatabaseTreeNode]) -> UUID? {
        guard listsConnections, let model = connectionsModel else { return nil }
        return DatabaseTreeConnectionRows.clickSwitchTarget(
            selected: nodes.map(\.kind),
            hostedHere: Set(model.host?.hostedConnectionIds ?? []),
            isPointerClick: Self.isPointerClick(NSApp.currentEvent)
        )
    }

    /// `NSTableView` moves the selection on mouse down, so a click is still the current event when
    /// the selection change arrives. A key press, type-select or a reload is not a click.
    internal static func isPointerClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .leftMouseDown || event.type == .leftMouseUp
    }

    /// Double click and Return on a saved connection other than the tree's own.
    internal func activateConnection(_ ref: DatabaseTreeSavedConnectionRef) {
        guard let model = connectionsModel else { return }
        let window = outlineView?.window
        switch DatabaseTreeConnectionRows.activation(of: ref, hostedHere: Set(model.host?.hostedConnectionIds ?? [])) {
        case .toggleDisclosure:
            guard let outlineView, let node = nodeCache[DatabaseTreeNode.savedConnectionId(ref.id)] else { return }
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        case .switchTo(let id):
            model.perform(.switchTo(id), presentingWindow: window)
        case .open(let id):
            model.perform(.open(id), presentingWindow: window)
        }
    }

    // MARK: - Menu

    /// A group or connection row takes the connections column's menu. Returns false for any other
    /// row, which keeps the tree's own menu.
    internal func fillConnectionMenu(_ menu: NSMenu, clicked: DatabaseTreeNode?) -> Bool {
        guard let model = connectionsModel, let clicked else { return false }
        let row: ConnectionNavigatorRowID
        switch clicked.kind {
        case .connectionGroup(let group):
            row = .group(group.id)
        case .savedConnection(let ref):
            row = .connection(ref.id)
        default:
            return false
        }
        SidebarMenuBuilder.fill(
            menu,
            with: ConnectionNavigatorMenu.sections(for: model.menuTarget(for: row)),
            target: self,
            action: #selector(performConnectionMenuCommand(_:))
        )
        return true
    }

    @objc
    internal func performConnectionMenuCommand(_ sender: NSMenuItem) {
        guard let model = connectionsModel,
              let box = sender.representedObject as? SidebarMenuCommandBox<ConnectionNavigatorCommand>
        else { return }
        guard case .newGroup(let parentId) = box.command else {
            model.perform(box.command, presentingWindow: outlineView?.window)
            return
        }
        presentNewGroupSheet(parentId: parentId)
    }

    /// The group sheet the Welcome window and the connections column use, saving through the same
    /// store. It is presented from the view controller hosting this outline, since SwiftUI's
    /// `dismiss` does not reach a sheet AppKit presents.
    private func presentNewGroupSheet(parentId: UUID?) {
        guard connectionGroupSheet == nil, let model = connectionsModel, let presenter = hostingViewController else {
            return
        }
        let sheet = GroupEditorSheet(
            mode: .create(parentId: parentId),
            groups: model.groups,
            onDismiss: { [weak self] in self?.dismissNewGroupSheet() },
            onSave: { [weak model] fields in try model?.createGroup(fields) }
        )
        let controller = NSHostingController(rootView: sheet)
        connectionGroupSheet = controller
        presenter.presentAsSheet(controller)
    }

    private func dismissNewGroupSheet() {
        guard let sheet = connectionGroupSheet else { return }
        connectionGroupSheet = nil
        sheet.presentingViewController?.dismiss(sheet)
    }

    private var hostingViewController: NSViewController? {
        var responder = outlineView?.nextResponder
        while let current = responder {
            if let controller = current as? NSViewController { return controller }
            responder = current.nextResponder
        }
        return nil
    }
}
