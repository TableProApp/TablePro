//
//  WorkspaceRailViewController.swift
//  TablePro
//

import AppKit
import Combine
import Observation
import OSLog

/// The window a rail belongs to. A window hosts several connections and shows one at a time, so
/// which row the rail highlights is a question only the window can answer, and the answer changes.
/// The rail used to capture the connection its window was created for, which could name the right
/// row exactly once: after the window switched to a second connection the rail kept highlighting
/// the first, and clicking the row it was already standing on did nothing.
@MainActor
internal protocol WorkspaceRailHost: AnyObject {
    var hostedConnectionIds: [UUID] { get }
    var selectedConnectionId: UUID? { get }
    func selectHostedConnection(_ connectionId: UUID)
}

/// Middle-click closes the row under the pointer, which is what a list of open things does
/// everywhere it exists: browser tabs, and every database client surveyed. `NSTableView` routes no
/// action for the tertiary button, so the row is resolved from the click point the same way
/// `menu(for:)` resolves one.
@MainActor
internal final class WorkspaceRailTableView: NSTableView {
    internal var onMiddleClick: ((Int) -> Void)?

    override internal func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        guard clicked >= 0 else { return }
        onMiddleClick?(clicked)
    }
}

@MainActor
internal final class WorkspaceRailViewController: NSViewController {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WorkspaceRail")
    private static let reorderType = NSPasteboard.PasteboardType("com.TablePro.workspaceRailEntry")

    internal var onLayoutChange: ((WorkspaceRailMetrics.Layout) -> Void)?
    internal var onEntryCountChange: ((Int) -> Void)?
    internal weak var host: (any WorkspaceRailHost)?

    private let scrollView = NSScrollView()
    private let tableView = WorkspaceRailTableView()

    /// `rowSizeStyle` is the only route to the sidebar icon size preference, but any value
    /// other than `.custom` makes the table impose the system row height and ignore
    /// `heightOfRow`, which the rail's stacked cell needs. This unattached table lets AppKit
    /// resolve the preference so the rail itself can stay `.custom`.
    private let rowSizeProbe = NSTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))

    private var entries: [WorkspaceRailEntry] = []
    private var layout: WorkspaceRailMetrics.Layout = WorkspaceRailMetrics.medium
    private var changeCancellable: AnyCancellable?
    private var activationObserver: (any NSObjectProtocol)?
    private var contentTopConstraint: NSLayoutConstraint?

    /// What the rail last put on screen as selected, which after every `applySelection` is the
    /// workspace the host is really showing. A commit for that same workspace has nothing to do,
    /// and is the case the arrow keys hit constantly as they move the highlight across a row the
    /// window is already on.
    private var appliedSelection: WorkspaceID?

    internal init() {
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
        tableView.onMiddleClick = { [weak self] row in self?.closeConnection(atRow: row) }
        tableView.setAccessibilityIdentifier("workspace-rail")
        tableView.setAccessibilityLabel(String(localized: "Open Connections"))

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
        /// Changing the Appearance setting means leaving TablePro and coming back, and AppKit
        /// publishes that. `effectiveRowSizeStyle` is then re-read, which is the documented way to
        /// ask what the system resolved. The undocumented defaults key this used to observe is gone.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLayoutIfNeeded() }
        }
        observeRowSizePreference()
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        pinContentBelowTitleBar()
        refreshLayoutIfNeeded()
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
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
        guard let connectionId = host?.selectedConnectionId else { return "none" }
        return String(connectionId.uuidString.prefix(8))
    }

    /// Re-arms itself, because `withObservationTracking` fires once per registration.
    private func observeRowSizePreference() {
        withObservationTracking {
            _ = AppSettingsManager.shared.general.sidebarRowSize
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshLayoutIfNeeded()
                self.observeRowSizePreference()
            }
        }
    }

    /// The rail sits directly beside the object list, so it takes the same size. Following only the
    /// system preference left the two disagreeing the moment the user set a size of their own.
    private var resolvedRowSizeStyle: NSTableView.RowSizeStyle {
        let preference = AppSettingsManager.shared.general.sidebarRowSize
        guard preference == .matchSystem else {
            return SidebarRowSizeResolver.rowSizeStyle(for: preference)
        }
        return rowSizeProbe.effectiveRowSizeStyle
    }

    internal func refreshLayoutIfNeeded() {
        let resolved = WorkspaceRailMetrics.layout(for: resolvedRowSizeStyle)
        guard resolved != layout else { return }
        layout = resolved
        tableView.sizeLastColumnToFit()
        tableView.reloadData()
        applySelection()
        onLayoutChange?(resolved)
    }

    /// Both halves move: the window switches which connection it shows, and that connection
    /// switches which container it browses. Neither can be captured at init.
    private var activeWorkspace: WorkspaceID? {
        guard let connectionId = host?.selectedConnectionId else { return nil }
        return WorkspaceRailStore.browsedWorkspace(for: connectionId)
    }

    /// Called when the window changes which connection it is showing. The entry list is unchanged
    /// by that, only which row is current, so this moves the highlight instead of reloading.
    internal func refreshSelection() {
        applySelection()
    }

    private func applySelection() {
        let browsed = activeWorkspace
        guard let row = WorkspaceRailStore.selectedRow(
            connectionId: host?.selectedConnectionId,
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

    /// Close means the connection highlighted here while the strip holds the keyboard.
    ///
    /// The selector is the window's, deliberately: `performClose:` reaching the responder chain
    /// finds this implementation before the window's whenever the strip is focused, which is the
    /// same mechanism that gives Cut and Copy a different meaning in each view. The window used to
    /// ask whether the strip had focus and branch on the answer, which is this rule written out by
    /// hand.
    @objc
    internal func performClose(_ sender: Any?) {
        guard let workspace = appliedSelection else {
            /// Nothing highlighted means the strip has no connection to close, not that Close does
            /// nothing: swallowing it here would leave the command dead in a window that has tabs,
            /// which is the failure this whole route exists to prevent.
            view.window?.performClose(sender)
            return
        }
        close(connectionId: workspace.connectionId)
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
    ///
    /// Both paths end at `applySelection`, which reads the host's own selection back. A workspace
    /// this window hosts leaves the highlight on the row the user picked; one belonging to another
    /// window leaves it where it was, because this window did not move. The rail needed a rule for
    /// when to put its highlight back only while it was guessing at the answer.
    private func activate(_ workspace: WorkspaceID) {
        /// One window hosts every connection, so switching is a selection change in that
        /// window's own registry. Raising a different window is what made the rail read as a
        /// window switcher rather than a workspace switcher.
        if let host, host.hostedConnectionIds.contains(workspace.connectionId) {
            host.selectHostedConnection(workspace.connectionId)
            if let window = view.window {
                moveBrowseCursor(of: window, to: workspace)
            }
            applySelection()
            return
        }

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
        moveBrowseCursor(of: window, to: workspace)
        applySelection()
    }

    /// Both halves of going to a workspace: the object tree moves to its container, and the window
    /// lands on the work that container already holds. They run in one place, in that order,
    /// because the switch is asynchronous and a second trigger would select a tab against a cursor
    /// that had not moved yet.
    private func moveBrowseCursor(of window: NSWindow, to workspace: WorkspaceID) {
        guard !workspace.container.isEmpty else {
            Self.logger.debug("moveBrowseCursor skipped: unnamed container")
            return
        }
        /// Resolved by connection through the window that hosts it, never by window alone.
        /// `coordinator(forWindow:)` answers with the window's selected workspace, so a row for any
        /// other connection moved the browse cursor of the one on screen instead: it switched the
        /// visible connection to a database named after a different one, or failed against a
        /// database that connection does not have.
        guard let coordinator = WindowManager.shared.coordinator(for: workspace.connectionId) else {
            Self.logger.error(
                """
                moveBrowseCursor has no coordinator target=\(Self.describe(workspace), privacy: .public) \
                window=\(window.windowNumber, privacy: .public)
                """
            )
            return
        }
        let current = WorkspaceRailStore.browsedWorkspace(for: workspace.connectionId)
        guard current != workspace else {
            Self.logger.debug(
                "moveBrowseCursor skipped: already at \(Self.describe(workspace), privacy: .public)"
            )
            coordinator.selectTab(inContainer: workspace.container)
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
                /// Only once the cursor is really there. A failed switch has already told the user
                /// why, and selecting that container's tab on top of it would leave the window
                /// showing one database while the tree lists another.
                coordinator.selectTab(inContainer: workspace.container)
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
    private func openInNewWindow(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID else { return }
        WindowManager.shared.moveToNewWindow(connectionId: workspace.connectionId)
    }

    @objc
    private func closeConnection(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID else { return }
        close(connectionId: workspace.connectionId)
    }

    private func closeConnection(atRow row: Int) {
        guard entries.indices.contains(row) else { return }
        close(connectionId: entries[row].workspace.connectionId)
    }

    private func close(connectionId: UUID) {
        Task { await ConnectionCloseAction.close(connectionId: connectionId) }
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

// MARK: - CloseCommandNaming

extension WorkspaceRailViewController: CloseCommandNaming {
    /// The strip's own contextual menu names the connection it would close, and the menu bar has to
    /// agree with it: the command is the same one.
    /// nil while nothing is highlighted, so the resolver falls back to the window, which is where
    /// the command goes in that state too.
    internal var closeCommandTitle: String? {
        guard let workspace = appliedSelection,
              let entry = entries.first(where: { $0.workspace == workspace })
        else { return nil }
        return String(format: String(localized: "Close “%@”"), entry.connection.name)
    }
}

// MARK: - NSMenuDelegate

extension WorkspaceRailViewController: NSMenuDelegate {
    /// Lighter action first, the one that ends the connection last, which is the order Finder uses
    /// on a Locations row and Mail on an account. Close carries the connection's own name because
    /// a row can be one of several a connection has open, and the command takes all of them.
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]

        if WindowManager.shared.canMoveToNewWindow(connectionId: entry.workspace.connectionId) {
            addItem(
                to: menu,
                title: String(localized: "Open in New Window"),
                action: #selector(openInNewWindow(_:)),
                workspace: entry.workspace
            )
            menu.addItem(.separator())
        }

        if ConnectionMenuPolicy.showsDisconnect(status: entry.status) {
            addItem(
                to: menu,
                title: String(localized: "Disconnect"),
                action: #selector(disconnectWorkspace(_:)),
                workspace: entry.workspace
            )
            menu.addItem(.separator())
        }

        addItem(
            to: menu,
            title: String(format: String(localized: "Close “%@”"), entry.connection.name),
            action: #selector(closeConnection(_:)),
            workspace: entry.workspace
        )
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, workspace: WorkspaceID) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = workspace
        menu.addItem(item)
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
