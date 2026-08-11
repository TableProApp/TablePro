//
//  WorkspaceRailViewController.swift
//  TablePro
//

import AppKit
import Combine
import OSLog

/// Reads System Settings > Appearance > Sidebar icon size. `UserDefaults` is KVO compliant
/// for its keys, and the `@objc` name is what the observation resolves to, so the rail is
/// told when the preference changes instead of noticing at the next layout pass.
private extension UserDefaults {
    @objc(NSTableViewDefaultSizeMode)
    dynamic var tableViewDefaultSizeMode: Int {
        integer(forKey: "NSTableViewDefaultSizeMode")
    }
}

@MainActor
internal final class WorkspaceRailViewController: NSViewController {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WorkspaceRail")
    private static let reorderType = NSPasteboard.PasteboardType("com.TablePro.workspaceRailEntry")

    internal var onLayoutChange: ((WorkspaceRailMetrics.Layout) -> Void)?
    internal var onEntryCountChange: ((Int) -> Void)?

    private let connectionId: UUID?
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    /// `rowSizeStyle` is the only route to the sidebar icon size preference, but any value
    /// other than `.custom` makes the table impose the system row height and ignore
    /// `heightOfRow`, which the rail's stacked cell needs. This unattached table lets AppKit
    /// resolve the preference so the rail itself can stay `.custom`.
    private let rowSizeProbe = NSTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))

    private var entries: [WorkspaceRailEntry] = []
    private var layout: WorkspaceRailMetrics.Layout = WorkspaceRailMetrics.medium
    private var changeCancellable: AnyCancellable?
    private var sizeModeObservation: NSKeyValueObservation?
    private var contentTopConstraint: NSLayoutConstraint?

    /// What the rail last put on screen as selected. A selection that differs from this came
    /// from the user, whether by click, arrow key, type-select or VoiceOver, and is the one
    /// signal the rail acts on. Recording the applied value rather than raising a re-entrancy
    /// flag is what lets AppKit's own selection stand as the model.
    private var appliedSelection: WorkspaceID?

    internal init(connectionId: UUID?) {
        self.connectionId = connectionId
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceRailViewController does not support NSCoder init")
    }

    internal var currentLayout: WorkspaceRailMetrics.Layout {
        layout
    }

    override func loadView() {
        view = NSView()

        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .custom
        rowSizeProbe.rowSizeStyle = .default
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleRowClick)
        tableView.menu = contextMenu()
        tableView.registerForDraggedTypes([Self.reorderType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityIdentifier("workspace-rail")
        tableView.setAccessibilityLabel(String(localized: "Open Workspaces"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pinContentBelowTitleBar()
    }

    /// The rail is a full-height sidebar, so AppKit gives it a top safe-area inset that
    /// clears the window buttons and does not move when the native tab bar appears.
    /// Anchoring to `NSWindow.contentLayoutGuide` instead tracked the tab bar and made the
    /// rail jump between workspaces with different tab counts.
    private func pinContentBelowTitleBar() {
        contentTopConstraint?.isActive = false
        let constraint = scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        constraint.isActive = true
        contentTopConstraint = constraint
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        changeCancellable = WorkspaceRailStore.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
        sizeModeObservation = UserDefaults.standard.observe(
            \.tableViewDefaultSizeMode,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.refreshLayoutIfNeeded() }
        }
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        pinContentBelowTitleBar()
        refreshLayoutIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
    }

    // MARK: - Data

    private func reload() {
        entries = WorkspaceRailStore.entries
        Self.logger.debug(
            """
            reload rail=\(self.railName, privacy: .public) \
            entries=\(self.entries.count, privacy: .public) \
            [\(self.entries.map(\.workspace).map(Self.describe).joined(separator: " "), privacy: .public)]
            """
        )
        tableView.reloadData()
        applySelection()
        onEntryCountChange?(entries.count)
    }

    private static func describe(_ workspace: WorkspaceID) -> String {
        "\(workspace.connectionId.uuidString.prefix(8)):\(workspace.container.isEmpty ? "-" : workspace.container)"
    }

    /// Which window's rail a line came from. Every rail lists every workspace, so without this
    /// a log of two connections switching back and forth cannot be attributed.
    private var railName: String {
        guard let connectionId else { return "none" }
        return String(connectionId.uuidString.prefix(8))
    }

    private func refreshLayoutIfNeeded() {
        let resolved = WorkspaceRailMetrics.layout(for: rowSizeProbe.effectiveRowSizeStyle)
        guard resolved != layout else { return }
        layout = resolved
        tableView.sizeLastColumnToFit()
        tableView.reloadData()
        applySelection()
        onLayoutChange?(resolved)
    }

    /// The browsed container moves, so the selected row is resolved on every reload rather
    /// than fixed at init the way the window's connection is.
    private var activeWorkspace: WorkspaceID? {
        guard let connectionId else { return nil }
        return WorkspaceRailStore.browsedWorkspace(for: connectionId)
    }

    private func applySelection() {
        let browsed = activeWorkspace
        guard let row = WorkspaceRailStore.selectedRow(
            connectionId: connectionId,
            browsed: browsed,
            in: entries.map(\.id)
        ) else {
            Self.logger.debug(
                """
                applySelection rail=\(self.railName, privacy: .public) \
                browsed=\(browsed.map(Self.describe) ?? "none", privacy: .public) row=none
                """
            )
            appliedSelection = nil
            tableView.deselectAll(nil)
            return
        }
        appliedSelection = entries[row].workspace
        Self.logger.debug(
            """
            applySelection rail=\(self.railName, privacy: .public) \
            browsed=\(browsed.map(Self.describe) ?? "none", privacy: .public) \
            row=\(row, privacy: .public) applied=\(Self.describe(self.entries[row].workspace), privacy: .public)
            """
        )
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - Activation

    @objc
    private func handleRowClick() {
        commit(row: tableView.clickedRow)
    }

    /// Return opens the highlighted row, the same contract every AppKit list keeps. `NSTableView`
    /// routes it here through the responder chain, so no key handling of the rail's own is needed.
    override func insertNewline(_ sender: Any?) {
        commit(row: tableView.selectedRow)
    }

    private func commit(row: Int) {
        guard entries.indices.contains(row) else { return }
        let workspace = entries[row].workspace
        guard workspace != appliedSelection else {
            Self.logger.debug(
                "commit rail=\(self.railName, privacy: .public) ignored: already at \(Self.describe(workspace), privacy: .public)"
            )
            return
        }
        Self.logger.info(
            """
            commit rail=\(self.railName, privacy: .public) row=\(row, privacy: .public) \
            was=\(self.appliedSelection.map(Self.describe) ?? "none", privacy: .public) \
            now=\(Self.describe(workspace), privacy: .public)
            """
        )
        appliedSelection = workspace
        activate(workspace)
    }

    /// Every rail entry is backed by a live window, so the window is raised directly rather
    /// than routed through `TabRouter.openConnection`, which resolves the id against
    /// `ConnectionStorage` and would fail for a connection opened from a URL that was never
    /// saved. Moving between two containers of the same connection stays in one window and
    /// only moves that window's browse cursor.
    private func activate(_ workspace: WorkspaceID) {
        let target = entries.first { $0.workspace == workspace }?.containerTarget
        let showing = MainContentCoordinator.window(showing: workspace, target: target)
        guard let window = showing
            ?? WindowLifecycleMonitor.shared.mostRecentWindow(for: workspace.connectionId) else {
            Self.logger.error(
                "activate has no window target=\(Self.describe(workspace), privacy: .public)"
            )
            return
        }

        let group = window.tabGroup
        Self.logger.info(
            """
            activate rail=\(self.railName, privacy: .public) \
            target=\(Self.describe(workspace), privacy: .public) \
            window=\(window.windowNumber, privacy: .public) visible=\(window.isVisible, privacy: .public) \
            tabs=\(group?.windows.count ?? 0, privacy: .public) \
            wasSelectedTab=\(group?.selectedWindow === window, privacy: .public) \
            showsItsOwnWork=\(showing != nil, privacy: .public)
            """
        )

        /// A background tab is a window AppKit will happily make key without bringing to the
        /// front of its group, which reads as the click doing nothing. Selecting it in the
        /// group first is the documented way to raise a specific tab.
        if let group, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        moveBrowseCursor(of: window, to: workspace, target: target)

        guard WorkspaceRailStore.shouldRestoreSelection(
            after: workspace,
            railConnectionId: connectionId
        ) else { return }
        applySelection()
    }

    private func moveBrowseCursor(of window: NSWindow, to workspace: WorkspaceID, target: ContainerSwitchTarget?) {
        guard !workspace.container.isEmpty else {
            Self.logger.debug("moveBrowseCursor skipped: unnamed container")
            return
        }
        let current = WorkspaceRailStore.browsedWorkspace(for: workspace.connectionId)
        guard current != workspace else {
            Self.logger.debug(
                "moveBrowseCursor skipped: already at \(Self.describe(workspace), privacy: .public)"
            )
            return
        }
        guard let coordinator = MainContentCoordinator.coordinator(forWindow: window) else {
            Self.logger.error(
                """
                moveBrowseCursor has no coordinator target=\(Self.describe(workspace), privacy: .public) \
                window=\(window.windowNumber, privacy: .public)
                """
            )
            return
        }
        Self.logger.info(
            """
            moveBrowseCursor from=\(current.map(Self.describe) ?? "none", privacy: .public) \
            to=\(Self.describe(workspace), privacy: .public)
            """
        )
        Task { @MainActor in
            await coordinator.switchContainer(to: workspace.container)
            let landed = WorkspaceRailStore.browsedWorkspace(for: workspace.connectionId)
            if landed == workspace {
                Self.logger.info("moveBrowseCursor landed \(Self.describe(workspace), privacy: .public)")
                coordinator.selectTab(in: workspace, target: target)
            } else {
                Self.logger.error(
                    """
                    moveBrowseCursor did not land wanted=\(Self.describe(workspace), privacy: .public) \
                    got=\(landed.map(Self.describe) ?? "none", privacy: .public)
                    """
                )
            }
            self.applySelection()
        }
    }

    /// The menu command is a commit, not a highlight: it names the workspace it goes to, so it
    /// has to get there without a second keystroke.
    internal func activateWorkspace(offsetBy offset: Int) {
        guard let next = WorkspaceRailOrdering.cycled(
            in: entries.map(\.id),
            from: appliedSelection,
            by: offset
        ) else { return }
        guard let row = entries.firstIndex(where: { $0.id == next }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        commit(row: row)
    }

    // MARK: - Context Menu

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc
    private func closeWorkspace(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID else { return }
        guard let window = WindowLifecycleMonitor.shared.mostRecentWindow(for: workspace.connectionId),
              let coordinator = MainContentCoordinator.coordinator(forWindow: window) else { return }
        coordinator.commandActions?.closeWorkspace(container: workspace.container)
    }

    /// Ends the session, which every workspace of the connection shares, so the other rows for it
    /// go quiet too. No window closes: each one repaints from its own phase.
    @objc
    private func disconnectWorkspace(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID,
              let entry = entries.first(where: { $0.workspace.connectionId == workspace.connectionId })
        else { return }
        /// The rail's own window, not the connection's most recent one: the user is looking at this
        /// window, and the connection's most recent window can be behind it or miniaturized, which
        /// would put the confirmation sheet somewhere they cannot see and read as a dead menu item.
        let presentingWindow = view.window
        Task {
            await ConnectionDisconnectAction.disconnect(
                connectionId: workspace.connectionId,
                connectionName: entry.connection.name,
                presentingWindow: presentingWindow
            )
        }
    }
}

// MARK: - NSMenuDelegate

extension WorkspaceRailViewController: NSMenuDelegate {
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard entries.indices.contains(row) else { return }

        let item = NSMenuItem(
            title: String(localized: "Close Workspace"),
            action: #selector(closeWorkspace(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entries[row].workspace
        menu.addItem(item)

        guard ConnectionMenuPolicy.showsDisconnect(status: entries[row].status) else { return }
        let disconnectItem = NSMenuItem(
            title: String(localized: "Disconnect"),
            action: #selector(disconnectWorkspace(_:)),
            keyEquivalent: ""
        )
        disconnectItem.target = self
        disconnectItem.representedObject = entries[row].workspace
        menu.addItem(disconnectItem)
    }
}

// MARK: - NSTableViewDataSource

extension WorkspaceRailViewController: NSTableViewDataSource {
    internal func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    internal func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard entries.indices.contains(row) else { return nil }
        guard let data = try? JSONEncoder().encode(entries[row].workspace) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.reorderType)
        return item
    }

    internal func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        guard dropOperation == .above else {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        return .move
    }

    internal func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let data = info.draggingPasteboard.data(forType: Self.reorderType),
              let moved = try? JSONDecoder().decode(WorkspaceID.self, from: data) else { return false }

        let reordered = WorkspaceRailOrdering.reordered(entries.map(\.id), moving: moved, toRow: row)
        guard reordered != entries.map(\.id) else { return false }

        WorkspaceRailStore.applyVisibleOrder(reordered)
        return true
    }
}

// MARK: - NSTableViewDelegate

extension WorkspaceRailViewController: NSTableViewDelegate {
    internal func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        layout.rowHeight
    }

    internal func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard entries.indices.contains(row) else { return nil }

        let cell = tableView.makeView(
            withIdentifier: WorkspaceRailCellView.reuseIdentifier,
            owner: self
        ) as? WorkspaceRailCellView ?? WorkspaceRailCellView(frame: .zero)

        cell.configure(entry: entries[row], layout: layout)
        return cell
    }

    /// Selection is the highlight, not the commit.
    ///
    /// `NSTableView` selects on mouse-down, before the drag threshold, so committing here meant
    /// grabbing an icon to reorder first switched to it and the rest of the drag happened in a
    /// window that was no longer key. Arrow keys were worse: one press onto another connection's
    /// row raised that window, so the rail lost key status and the next press went somewhere else
    /// entirely. Commit belongs on the table's action, which fires after tracking ends, and on
    /// Return, which is how every AppKit list opens the row the user arrowed to.
    internal func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard entries.indices.contains(row) else { return }
        Self.logger.debug(
            """
            selectionDidChange rail=\(self.railName, privacy: .public) row=\(row, privacy: .public) \
            highlight=\(Self.describe(self.entries[row].workspace), privacy: .public)
            """
        )
    }
}
