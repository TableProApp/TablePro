//
//  ConnectionTreeOutlineController.swift
//  TablePro
//

import AppKit
import Combine
import os

/// The window a connections tree belongs to.
///
/// A window hosts several connections and shows one at a time, so which row is selected and what
/// state each row is in are questions only the window can answer, and both answers change while the
/// tree is on screen.
@MainActor
internal protocol ConnectionTreeHost: AnyObject {
    var hostedConnectionIds: [UUID] { get }
    var selectedConnectionId: UUID? { get }
    func selectHostedConnection(_ connectionId: UUID)
    /// Nil for a connection this window does not host, which is every saved connection the user has
    /// not opened here. That is a different row from one whose workspace exists and is idle, which
    /// is why `ConnectionTreeStatus` takes an optional phase rather than a phase.
    func connectionPhase(for connectionId: UUID) -> ConnectionWindowPhase?
    func openConnectionInWindow(_ connectionId: UUID)
}

/// Lists every saved connection, grouped as the user filed them, with the state of the ones this
/// window hosts.
///
/// This replaces the workspace rail, which listed only the connections a window already had open.
/// A list of the connections you can open is the thing a database client's sidebar is for; a list
/// of the ones already open answers a question the editor tabs already answer.
@MainActor
internal final class ConnectionTreeOutlineController: NSViewController {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionTree")

    internal weak var host: (any ConnectionTreeHost)?
    internal var onRowCountChange: ((Int) -> Void)?

    /// Reached by `ConnectionTreeOutlineController+Menu`, which is why these are internal: a
    /// Swift extension in another file cannot see `private`.
    internal let outlineView = NSOutlineView()
    private var scrollView: NSScrollView!

    private var layout = ConnectionTreeRootBuilder.Layout.empty
    internal var connectionsById: [UUID: DatabaseConnection] = [:]

    /// Nodes are cached by id and mutated in place. `NSOutlineView` tracks rows by object identity,
    /// so handing it a fresh object for an id it already knows collapses everything under it.
    private var nodeCache: [String: ConnectionTreeNode] = [:]

    /// Expansion is the user's, and AppKit's single global autosave record cannot express one
    /// record per window, so it is held here for the life of the window.
    private var expandedGroupIds: Set<UUID> = []

    internal var autoExpansion = ConnectionTreeAutoExpansion()
    private var cancellables: Set<AnyCancellable> = []
    private var isApplyingSelection = false

    internal var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            reload()
        }
    }

    internal init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionTreeOutlineController does not support NSCoder init")
    }

    override func loadView() {
        scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: .init(
                columnIdentifier: "connection",
                allowsMultipleSelection: false,
                rowSizePreference: AppSettingsManager.shared.general.sidebarRowSize
            )
        )
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.setAccessibilityIdentifier("connection-tree")

        /// The menu hangs off the table, not off a row: that is what makes `NSTableView` set
        /// `clickedRow`, draw the clicked-row highlight, and answer a right-click in the empty area
        /// below the last row.
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges()
        reload()
    }

    // MARK: - Data

    private func observeChanges() {
        let events = AppEvents.shared
        events.connectionUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        events.connectionStatusChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStates() }
            .store(in: &cancellables)
    }

    internal func reload() {
        let connections = ConnectionStorage.shared.loadConnections()
        connectionsById = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        layout = ConnectionTreeRootBuilder.layout(
            groups: GroupStorage.shared.loadGroups(),
            connections: connections,
            searchText: searchText
        )
        pruneNodeCache()
        outlineView.reloadData()
        applyExpansion()
        refreshStates()
        applySelection()
        onRowCountChange?(layout.roots.count)
    }

    /// A node for an id that is no longer in the tree would keep its row alive across a reload, and
    /// a stale group node would keep a folder the user deleted.
    private func pruneNodeCache() {
        var live: Set<String> = []
        for kind in layout.roots {
            live.insert(ConnectionTreeRootBuilder.nodeID(for: kind))
            if case .group(let group) = kind {
                for child in layout.children(ofGroup: group.id) {
                    live.insert(ConnectionTreeRootBuilder.nodeID(for: child))
                }
            }
        }
        nodeCache = nodeCache.filter { live.contains($0.key) }
    }

    /// Only the state changes, so the rows are reconfigured in place: `reloadData` would collapse
    /// the folders the user opened every time a connection finished connecting.
    internal func refreshStates() {
        for row in 0 ..< outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? ConnectionTreeNode,
                  let connectionId = node.connectionId else { continue }
            let status = status(for: connectionId)
            guard status != node.status else { continue }
            node.status = status
            if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ConnectionTreeCellView,
               let connection = connectionsById[connectionId] {
                cell.configureConnection(connection, status: status)
            }
        }
        consumeAutoExpansion()
    }

    private func status(for connectionId: UUID) -> ConnectionTreeStatus {
        ConnectionTreeStatus(phase: host?.connectionPhase(for: connectionId))
    }

    private func cachedNode(for kind: ConnectionTreeNode.Kind) -> ConnectionTreeNode {
        let id = ConnectionTreeRootBuilder.nodeID(for: kind)
        if let cached = nodeCache[id] {
            cached.kind = kind
            return cached
        }
        let made = ConnectionTreeNode(id: id, kind: kind)
        if let connectionId = made.connectionId {
            made.status = status(for: connectionId)
        }
        nodeCache[id] = made
        return made
    }

    private func children(of item: Any?) -> [ConnectionTreeNode] {
        guard let node = item as? ConnectionTreeNode else {
            return layout.roots.map { cachedNode(for: $0) }
        }
        guard let group = node.group else { return [] }
        return layout.children(ofGroup: group.id).map { cachedNode(for: $0) }
    }

    // MARK: - Expansion and selection

    private func applyExpansion() {
        for kind in layout.roots {
            guard case .group(let group) = kind, expandedGroupIds.contains(group.id) else { continue }
            outlineView.expandItem(cachedNode(for: kind))
        }
    }

    private func consumeAutoExpansion() {
        for (_, connection) in connectionsById {
            let didArrive = autoExpansion.consume(connection.id, status: status(for: connection.id))
            guard didArrive else { continue }
            host?.selectHostedConnection(connection.id)
        }
    }

    internal func applySelection() {
        guard let selected = host?.selectedConnectionId,
              let row = row(forConnection: selected) else { return }
        isApplyingSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
    }

    private func row(forConnection connectionId: UUID) -> Int? {
        let id = ConnectionTreeRootBuilder.nodeID(for: .connection(connectionId))
        guard let node = nodeCache[id] else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    // MARK: - Activation

    @objc
    private func handleDoubleClick() {
        let clicked = outlineView.clickedRow
        guard clicked >= 0, let node = outlineView.item(atRow: clicked) as? ConnectionTreeNode else { return }
        activate(node, gesture: .doubleClick)
    }

    private func activate(_ node: ConnectionTreeNode, gesture: ConnectionTreeGesture) {
        if let group = node.group {
            let isExpanded = outlineView.isItemExpanded(node)
            switch ConnectionTreeActivationResolver.resolveGroup(gesture: gesture, isExpanded: isExpanded) {
            case .expand:
                expandedGroupIds.insert(group.id)
                outlineView.expandItem(node)
            case .collapse:
                expandedGroupIds.remove(group.id)
                outlineView.collapseItem(node)
            case .connect, .select, .nothing:
                break
            }
            return
        }

        guard let connectionId = node.connectionId else { return }
        switch ConnectionTreeActivationResolver.resolve(status: node.status, gesture: gesture) {
        case .connect:
            autoExpansion.expect(connectionId)
            host?.openConnectionInWindow(connectionId)
        case .select, .expand:
            host?.selectHostedConnection(connectionId)
        case .collapse, .nothing:
            break
        }
    }
}

// MARK: - Data source

extension ConnectionTreeOutlineController: NSOutlineViewDataSource {
    internal func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    internal func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    /// Answered here rather than by the node. `ConnectionTreeNode.isExpandable` reports a connection
    /// as expandable because the object tree is meant to hang under it; until it does, a triangle
    /// on a connection row would open onto nothing.
    internal func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ConnectionTreeNode, let group = node.group else { return false }
        return !layout.children(ofGroup: group.id).isEmpty
    }
}

// MARK: - Delegate

extension ConnectionTreeOutlineController: NSOutlineViewDelegate {
    internal func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? ConnectionTreeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: ConnectionTreeCellView.reuseIdentifier, owner: self)
            as? ConnectionTreeCellView ?? ConnectionTreeCellView(frame: .zero)

        if let group = node.group {
            cell.configureGroup(group, isExpanded: outlineView.isItemExpanded(node))
        } else if let connectionId = node.connectionId, let connection = connectionsById[connectionId] {
            node.status = status(for: connectionId)
            cell.configureConnection(connection, status: node.status)
        }
        return cell
    }

    internal func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    internal func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ConnectionTreeNode else { return }
        guard let connectionId = node.connectionId else { return }
        /// Selecting shows a connection this window already hosts and never starts a connect: that
        /// is the double-click, and arrowing down a list would otherwise dial every server in it.
        guard host?.hostedConnectionIds.contains(connectionId) == true else { return }
        host?.selectHostedConnection(connectionId)
    }

    internal func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ConnectionTreeNode,
              let group = node.group else { return }
        expandedGroupIds.insert(group.id)
    }

    internal func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ConnectionTreeNode,
              let group = node.group else { return }
        expandedGroupIds.remove(group.id)
    }
}
