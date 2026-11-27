import AppKit
import Combine
import Observation
import os
import OSLog
import TableProConnectionLibrary

// Only the window knows which of its connections is on screen, so the rail asks rather than capturing one.
@MainActor
internal protocol WorkspaceRailHost: AnyObject {
    var hostedConnectionIds: [UUID] { get }
    var selectedConnectionId: UUID? { get }
    func selectHostedConnection(_ connectionId: UUID)
}

// AppKit table on purpose: `NSTableView` routes no middle-click, and a source list pads rows a free cell never shows.
@MainActor
internal final class WorkspaceRailTableView: NSTableView {
    internal var onMiddleClick: ((Int) -> Void)?

    // Set the moment the strip hides: AppKit hides a collapsing item only after its animation, so the list could take first key view.
    internal var isStripShown = true

    override internal var canBecomeKeyView: Bool {
        isStripShown && super.canBecomeKeyView
    }

    override internal init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        headerView = nil
        style = .sourceList
        rowSizeStyle = .custom
        backgroundColor = .clear
        allowsMultipleSelection = false
        allowsEmptySelection = true
        // A source list draws the selection over the spacing, so the tile's own padding separates entries.
        intercellSpacing = NSSize(width: 0, height: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceRailTableView does not support NSCoder init")
    }

    // Read from the rows: the source list pads the first one down from the document's top.
    internal func scrollGeometry(viewportHeight: CGFloat) -> WorkspaceRailScrollGeometry {
        let first = numberOfRows > 0 ? rect(ofRow: 0) : .zero
        return WorkspaceRailScrollGeometry(
            rowCount: numberOfRows,
            rowHeight: first.height,
            firstRowTop: first.minY,
            viewportHeight: viewportHeight
        )
    }

    override internal func keyDown(with event: NSEvent) {
        guard !interpretCommandKey(event) else { return }
        super.keyDown(with: event)
    }

    override internal func accessibilityPerformShowMenu() -> Bool {
        showContextMenuForSelectedRow() || super.accessibilityPerformShowMenu()
    }

    override internal func otherMouseUp(with event: NSEvent) {
        guard event.isMiddleButton else {
            super.otherMouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        guard clicked >= 0 else { return }
        onMiddleClick?(clicked)
    }
}

internal struct WorkspaceRailServerTool: Equatable {
    internal let title: String
    internal let command: Selector
    internal let railAction: Selector
}

@MainActor
internal final class WorkspaceRailViewController: NSViewController {
    private var rowSizeObservation: AnyCancellable?
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WorkspaceRail")
    private static let reorderType = NSPasteboard.PasteboardType("com.TablePro.workspaceRailEntry")

    internal var onLayoutChange: ((WorkspaceRailMetrics.Layout) -> Void)?
    internal var onEntryCountChange: ((Int) -> Void)?
    internal var onWidthChange: (() -> Void)?
    internal weak var host: (any WorkspaceRailHost)?

    private let scrollView = NSScrollView()
    private let tableView = WorkspaceRailTableView()

    // Resolves the sidebar icon size; anything but `.custom` on the rail itself would ignore `heightOfRow`.
    private let rowSizeProbe = NSTableView()

    private var entries: [WorkspaceRailEntry] = []
    private var layout: WorkspaceRailMetrics.Layout = WorkspaceRailMetrics.medium {
        didSet { rowHeight = WorkspaceRailCellView.rowHeight(for: layout) }
    }
    private lazy var rowHeight = WorkspaceRailCellView.rowHeight(for: layout)
    private var reportedWidth: CGFloat = 0
    private var changeCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
    private let activationObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)
    private let scrollObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)
    private var contentTopConstraint: NSLayoutConstraint?

    // Settled once the scroll stops changing: a legacy mouse never posts the live-scroll pair.
    private var scrollSettle: DispatchWorkItem?

    // A reorder autoscrolls the strip, so settling during one would fight the drag.
    private var isReordering = false

    private var needsSelectionReveal = false

    // A commit for the workspace already applied has nothing to do, which is what the arrow keys hit constantly.
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

    internal var isStripShown: Bool {
        get { tableView.isStripShown }
        set { tableView.isStripShown = newValue }
    }

    override func loadView() {
        view = NSView()

        rowSizeProbe.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleRowClick)
        tableView.menu = contextMenu()
        tableView.registerForDraggedTypes([Self.reorderType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.onMiddleClick = { [weak self] row in self?.closeWorkspace(atRow: row) }
        tableView.setAccessibilityIdentifier("workspace-rail")
        tableView.setAccessibilityLabel(String(localized: "Open Connections"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        // Writing `contentInsets` clears the automatic flag anyway, and the safe area here is already zero.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pinContentBelowTitleBar()
    }

    // The safe-area inset clears the window buttons and stays put when the native tab bar appears; the content layout guide did not.
    private func pinContentBelowTitleBar() {
        contentTopConstraint?.isActive = false
        let constraint = scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        constraint.isActive = true
        contentTopConstraint = constraint
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        statusCancellable = WorkspaceRailStore.statusChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionId in
                self?.refreshStatus(of: connectionId)
            }
        changeCancellable = WorkspaceRailStore.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
        // An Appearance change happens outside the app, so the system row size is re-read on return.
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLayoutIfNeeded() }
        }
        activationObserver.withLockUnchecked { $0 = observer }
        observeScrollPosition()
        observeRowSizePreference()
        reload()
    }

    private func observeScrollPosition() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScrollSettle() }
        }
        scrollObserver.withLockUnchecked { $0 = observer }
    }

    // Re-armed on every bounds change, so the strip settles once scrolling stops, not once per frame.
    private func scheduleScrollSettle() {
        scrollSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleScrollPosition() }
        }
        scrollSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollSettleDelay, execute: work)
    }

    private static let scrollSettleDelay: TimeInterval = 0.12

    private func settleScrollPosition() {
        guard !isReordering else { return }
        let clipView = scrollView.contentView
        let settled = scrollGeometry.settledOrigin(
            proposed: clipView.bounds.origin.y,
            selectedRow: entries.indices.contains(tableView.selectedRow) ? tableView.selectedRow : nil
        )
        guard abs(settled - clipView.bounds.origin.y) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: settled))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(clipView)
        }
    }

    // Recomputed: the row count, the row height and the viewport all move.
    private var scrollGeometry: WorkspaceRailScrollGeometry {
        tableView.scrollGeometry(viewportHeight: scrollView.contentView.bounds.height)
    }

    private func applyBottomInset() {
        let inset = scrollGeometry.bottomInset(documentHeight: tableView.frame.height)
        guard abs(scrollView.contentInsets.bottom - inset) > 0.5 else { return }
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
    }

    // Held until the clip view has a height: no bounds notification follows a frame resize, and `NSTableView` never reveals a selection it already holds.
    private func requestSelectionReveal() {
        needsSelectionReveal = true
        revealSelectedRowIfNeeded()
    }

    private func revealSelectedRowIfNeeded() {
        guard needsSelectionReveal, scrollView.contentView.bounds.height > 0 else { return }
        needsSelectionReveal = false
        revealSelectedRow()
    }

    // Silent while the entry is whole on screen: every rail reloads on any window's change.
    private func revealSelectedRow() {
        let clipView = scrollView.contentView
        guard let origin = scrollGeometry.revealOrigin(
            row: tableView.selectedRow,
            currentOrigin: clipView.bounds.origin.y
        ) else { return }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: origin))
        scrollView.reflectScrolledClipView(clipView)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        pinContentBelowTitleBar()
        refreshLayoutIfNeeded()
    }

    deinit {
        if let observer = activationObserver.withLockUnchecked({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = scrollObserver.withLockUnchecked({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Not the split view's resize callback, which runs before the strip has its new width.
    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
        applyBottomInset()
        revealSelectedRowIfNeeded()
        guard view.frame.width != reportedWidth else { return }
        reportedWidth = view.frame.width
        onWidthChange?()
    }

    private func reload() {
        entries = WorkspaceRailStore.entries
        Self.logger.debug(
            """
            reload rail=\(self.railName, privacy: .public) \
            entries=\(self.entries.count, privacy: .public) \
            [\(self.entries.map(\.workspace).map(Self.describe).joined(separator: " "), privacy: .private(mask: .hash))]
            """
        )
        tableView.reloadData()
        applyBottomInset()
        applySelection()
        onEntryCountChange?(entries.count)
    }

    // A phase moves one connection's status and never which rows are listed, so only its rows repaint.
    private func refreshStatus(of connectionId: UUID) {
        let rows = IndexSet(entries.indices.filter { entries[$0].workspace.connectionId == connectionId })
        guard !rows.isEmpty else { return }
        let latest = WorkspaceRailStore.entries
        guard latest.map(\.id) == entries.map(\.id) else {
            reload()
            return
        }
        entries = latest
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    private static func describe(_ workspace: WorkspaceID) -> String {
        "\(workspace.connectionId.uuidString.prefix(8)):\(workspace.container.isEmpty ? "-" : workspace.container)"
    }

    // Every rail lists every workspace, so a log line names which window's rail wrote it.
    private var railName: String {
        guard let connectionId = host?.selectedConnectionId else { return "none" }
        return String(connectionId.uuidString.prefix(8))
    }

    private func observeRowSizePreference() {
        var lastRowSize = AppSettingsManager.shared.general.sidebarRowSize
        rowSizeObservation = AppSettingsManager.shared.generalSlice.onMainActorChange { [weak self] in
            let current = AppSettingsManager.shared.general.sidebarRowSize
            guard current != lastRowSize else { return }
            lastRowSize = current
            self?.refreshLayoutIfNeeded()
        }
    }

    // Same size as the object list beside it, including a size the user set.
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
        applyBottomInset()
        applySelection()
        // A scroll offset that moves nothing posts no bounds change, so neither the settle nor the reveal would run on its own.
        requestSelectionReveal()
        scheduleScrollSettle()
        onLayoutChange?(resolved)
    }

    // The entry this window shows, not the connection's browse cursor, which a torn-off window shares.
    private var activeWorkspace: WorkspaceID? {
        guard let connectionId = host?.selectedConnectionId else { return nil }
        if let shown = WindowManager.shared.coordinator(for: connectionId, in: view.window)?
            .tabManager.visibleContainer {
            return WorkspaceID(connectionId: connectionId, container: shown)
        }
        return WorkspaceRailStore.browsedWorkspace(for: connectionId)
    }

    // The entry list is unchanged by a connection switch, so only the highlight moves.
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
                browsed=\(browsed.map(Self.describe) ?? "none", privacy: .private(mask: .hash)) row=none
                """
            )
            appliedSelection = nil
            tableView.deselectAll(nil)
            return
        }
        let previousSelection = appliedSelection
        appliedSelection = entries[row].workspace
        Self.logger.debug(
            """
            applySelection rail=\(self.railName, privacy: .public) \
            browsed=\(browsed.map(Self.describe) ?? "none", privacy: .private(mask: .hash)) \
            row=\(row, privacy: .public) applied=\(Self.describe(self.entries[row].workspace), privacy: .private(mask: .hash))
            """
        )
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard previousSelection != appliedSelection else { return }
        requestSelectionReveal()
    }

    @objc
    private func handleRowClick() {
        commit(row: tableView.clickedRow)
    }

    override func insertNewline(_ sender: Any?) {
        commit(row: tableView.selectedRow)
    }

    // Found before the window's `performClose:` whenever the strip is focused; closes the connection when the entry is its only one.
    @objc
    internal func performClose(_ sender: Any?) {
        guard let workspace = appliedSelection else {
            // Swallowing Close here would leave the command dead in a window that has tabs.
            view.window?.performClose(sender)
            return
        }
        close(workspace)
    }

    private func commit(row: Int) {
        guard entries.indices.contains(row) else { return }
        let workspace = entries[row].workspace
        // Clicking the highlighted entry again retries a switch whose object browser stayed behind.
        guard workspace != appliedSelection
            || WorkspaceRailStore.browsedWorkspace(for: workspace.connectionId) != workspace
        else {
            Self.logger.debug(
                "commit rail=\(self.railName, privacy: .public) ignored: already at \(Self.describe(workspace), privacy: .private(mask: .hash))"
            )
            return
        }
        Self.logger.info(
            """
            commit rail=\(self.railName, privacy: .public) row=\(row, privacy: .public) \
            was=\(self.appliedSelection.map(Self.describe) ?? "none", privacy: .private(mask: .hash)) \
            now=\(Self.describe(workspace), privacy: .private(mask: .hash))
            """
        )
        appliedSelection = workspace
        activate(workspace)
    }

    // `applySelection` reads the window back, so a row another window hosts leaves this rail's highlight where it was.
    private func activate(_ workspace: WorkspaceID) {
        guard let shown = show(workspace) else { return }
        moveBrowseCursor(of: shown.window, to: workspace)
        applySelection()
    }

    // Raised directly: `TabRouter.openConnection` resolves through `ConnectionStorage` and fails for an unsaved URL connection.
    private func show(_ workspace: WorkspaceID) -> (window: NSWindow, host: MainSplitViewController)? {
        guard let window = WindowManager.shared.window(for: workspace.connectionId),
              let host = window.contentViewController as? MainSplitViewController else {
            Self.logger.error(
                "show has no window target=\(Self.describe(workspace), privacy: .private(mask: .hash))"
            )
            return nil
        }

        // Before the raise, or the window comes forward still showing the connection it had.
        host.selectHostedConnection(workspace.connectionId)

        guard window !== view.window else { return (window, host) }

        let group = window.tabGroup
        Self.logger.info(
            """
            show rail=\(self.railName, privacy: .public) \
            target=\(Self.describe(workspace), privacy: .private(mask: .hash)) \
            window=\(window.windowNumber, privacy: .public) visible=\(window.isVisible, privacy: .public) \
            tabs=\(group?.windows.count ?? 0, privacy: .public) \
            wasSelectedTab=\(group?.selectedWindow === window, privacy: .public)
            """
        )

        // AppKit makes a background tab key without bringing it to the front of its group.
        if let group, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
        return (window, host)
    }

    // `BrowseCursorCoordinator.goToEntry` brings the tabs forward and moves the tree, in that order.
    private func moveBrowseCursor(of window: NSWindow, to workspace: WorkspaceID) {
        guard !workspace.container.isEmpty else {
            Self.logger.debug("moveBrowseCursor skipped: unnamed container")
            return
        }
        // By connection, never by window alone, which answers with the window's selected workspace.
        guard let coordinator = WindowManager.shared.coordinator(for: workspace.connectionId, in: window) else {
            Self.logger.error(
                """
                moveBrowseCursor has no coordinator target=\(Self.describe(workspace), privacy: .private(mask: .hash)) \
                window=\(window.windowNumber, privacy: .public)
                """
            )
            return
        }
        Self.logger.info("moveBrowseCursor to=\(Self.describe(workspace), privacy: .private(mask: .hash))")
        coordinator.browseCursorCoordinator.goToEntry(workspace.container)
    }

    // A commit, not a highlight: the command names where it goes.
    internal func activateWorkspace(offsetBy offset: Int) {
        guard let next = WorkspaceRailOrdering.cycled(
            in: entries.map(\.id),
            from: appliedSelection,
            by: offset
        ) else { return }
        guard let row = entries.firstIndex(where: { $0.id == next }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        requestSelectionReveal()
        commit(row: row)
    }

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

    // Not `showServerDashboard(_:)`: the rail sits ahead of the window in the responder chain and would take the menu bar's command.
    @objc
    private func showWorkspaceServerDashboard(_ sender: NSMenuItem) {
        runServerTool(#selector(MainSplitViewController.showServerDashboard(_:)), from: sender)
    }

    @objc
    private func showWorkspaceQueryInsights(_ sender: NSMenuItem) {
        runServerTool(#selector(MainSplitViewController.showQueryInsights(_:)), from: sender)
    }

    // Both tools are server-wide, so the browse cursor stays: going to the row's container would switch databases for nothing.
    private func runServerTool(_ command: Selector, from sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID,
              let shown = show(workspace) else { return }
        applySelection()
        guard MainSplitViewController.isEnabled(command, context: shown.host.menuValidationContext) else { return }
        NSApp.sendAction(command, to: shown.host, from: sender)
    }

    // The Database menu's titles, order and commands, offered on the menu bar's own answer.
    internal static func serverTools(offeredWith context: MenuValidationContext) -> [WorkspaceRailServerTool] {
        [
            WorkspaceRailServerTool(
                title: String(localized: "Server Dashboard"),
                command: #selector(MainSplitViewController.showServerDashboard(_:)),
                railAction: #selector(showWorkspaceServerDashboard(_:))
            ),
            WorkspaceRailServerTool(
                title: String(localized: "Query Insights"),
                command: #selector(MainSplitViewController.showQueryInsights(_:)),
                railAction: #selector(showWorkspaceQueryInsights(_:))
            ),
        ].filter { MainSplitViewController.isEnabled($0.command, context: context) }
    }

    private static func serverTools(for connectionId: UUID) -> [WorkspaceRailServerTool] {
        let host = WindowManager.shared.window(for: connectionId)?.contentViewController as? MainSplitViewController
        guard let context = host?.menuValidationContext(forHosted: connectionId) else { return [] }
        return serverTools(offeredWith: context)
    }

    @objc
    private func closeWorkspace(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID else { return }
        close(workspace)
    }

    // Not `closeConnection(_:)`: that is the File menu's nil-target action, and the rail sits ahead of its owner in the responder chain.
    @objc
    private func closeWorkspaceConnection(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID else { return }
        close(connectionId: workspace.connectionId)
    }

    private func closeWorkspace(atRow row: Int) {
        guard entries.indices.contains(row) else { return }
        close(entries[row].workspace)
    }

    private func close(_ workspace: WorkspaceID) {
        Task { await WorkspaceCloseAction.close(workspace) }
    }

    // Named after the container: "Close %@" reads as closing the connection in some languages.
    internal static func containerCloseTitle(for entry: WorkspaceRailEntry) -> String {
        let format = entry.containerTarget == .schema
            ? String(localized: "Close Schema “%@”")
            : String(localized: "Close Database “%@”")
        return String(format: format, entry.container)
    }

    private func closeScope(for workspace: WorkspaceID) -> WorkspaceCloseAction.Scope {
        guard !workspace.container.isEmpty else { return .connection }
        let count = entries.count { $0.workspace.connectionId == workspace.connectionId }
        return WorkspaceCloseAction.scope(entryCount: count)
    }

    private func close(connectionId: UUID) {
        Task { await ConnectionCloseAction.close(connectionId: connectionId) }
    }

    // Releases the database file and keeps the session, so tabs, schema cache and position stay; the next query takes it again.
    @objc
    private func releaseWorkspaceFileLock(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID,
              let entry = entries.first(where: { $0.workspace.connectionId == workspace.connectionId })
        else { return }
        let presentingWindow = view.window
        Task {
            await ConnectionFileLockAction.release(
                connectionId: workspace.connectionId,
                connectionName: entry.connection.name,
                presentingWindow: presentingWindow
            )
        }
    }

    // Run by the hosting window so its pane shows the attempt and any failure; re-read, as the menu may have stayed open.
    @objc
    private func performWorkspaceConnectionAction(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID,
              let action = ConnectionMenuPolicy.primaryAction(
                  status: ConnectionStatusResolver.status(for: workspace.connectionId)
              ),
              let shown = show(workspace)
        else { return }
        applySelection()
        shown.host.performConnectionAction(action, for: workspace.connectionId)
    }

    // Every workspace of the connection shares the session, so its other rows go quiet too; no window closes.
    @objc
    private func disconnectWorkspace(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID,
              let entry = entries.first(where: { $0.workspace.connectionId == workspace.connectionId })
        else { return }
        // This window, not the connection's most recent one, which can be behind it or miniaturized.
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

extension WorkspaceRailViewController: CloseCommandNaming {
    // Matches the strip's own menu word for word; nil while nothing is highlighted, so the window's title applies.
    internal var closeCommandTitle: String? {
        guard let workspace = appliedSelection,
              let entry = entries.first(where: { $0.workspace == workspace })
        else { return nil }
        guard closeScope(for: workspace) == .container else {
            return String(format: String(localized: "Close Connection “%@”"), entry.connection.name)
        }
        return Self.containerCloseTitle(for: entry)
    }
}

extension WorkspaceRailViewController: NSMenuDelegate {
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        populate(menu, for: entry, serverTools: Self.serverTools(for: entry.workspace.connectionId))
    }

    // Lighter actions first and the one that ends the connection last, the order Finder and Mail keep.
    internal func populate(_ menu: NSMenu, for entry: WorkspaceRailEntry, serverTools: [WorkspaceRailServerTool]) {
        if let title = entry.presentation.primaryActionTitle {
            addItem(
                to: menu,
                title: title,
                action: #selector(performWorkspaceConnectionAction(_:)),
                workspace: entry.workspace
            )
            menu.addItem(.separator())
        }

        if WindowManager.shared.canMoveToNewWindow(connectionId: entry.workspace.connectionId) {
            addItem(
                to: menu,
                title: String(localized: "Open in New Window"),
                action: #selector(openInNewWindow(_:)),
                workspace: entry.workspace
            )
            menu.addItem(.separator())
        }

        // No key equivalent: a context item's chord would run on the window's connection, not the row's.
        for tool in serverTools {
            addItem(to: menu, title: tool.title, action: tool.railAction, workspace: entry.workspace)
        }
        if !serverTools.isEmpty {
            menu.addItem(.separator())
        }

        if let releaseTitle = ConnectionFileLockAction.commandTitle(
            connectionId: entry.workspace.connectionId
        ) {
            addItem(
                to: menu,
                title: releaseTitle,
                action: #selector(releaseWorkspaceFileLock(_:)),
                workspace: entry.workspace
            )
        }

        if ConnectionMenuPolicy.showsDisconnect(status: entry.status, holdsSession: entry.holdsSession) {
            addItem(
                to: menu,
                title: String(localized: "Disconnect"),
                action: #selector(disconnectWorkspace(_:)),
                workspace: entry.workspace
            )
            menu.addItem(.separator())
        }

        if closeScope(for: entry.workspace) == .container {
            addItem(
                to: menu,
                title: Self.containerCloseTitle(for: entry),
                action: #selector(closeWorkspace(_:)),
                workspace: entry.workspace
            )
        }

        addItem(
            to: menu,
            title: String(format: String(localized: "Close Connection “%@”"), entry.connection.name),
            action: #selector(closeWorkspaceConnection(_:)),
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

extension WorkspaceRailViewController: NSTableViewDataSource {
    internal func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    internal func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        isReordering = true
    }

    internal func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isReordering = false
        scheduleScrollSettle()
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

extension WorkspaceRailViewController: NSTableViewDelegate {
    internal func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight
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

    internal func tableView(
        _ tableView: NSTableView,
        nextTypeSelectMatchFromRow startRow: Int,
        toRow endRow: Int,
        for searchString: String
    ) -> Int {
        WorkspaceRailTypeSelect.nextMatch(
            in: entries,
            from: startRow,
            to: endRow,
            search: searchString
        )
    }

    // Selection is the highlight, not the commit: `NSTableView` selects on mouse-down, before a reorder drag starts.
    internal func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard entries.indices.contains(row) else { return }
        // `NSTableView` scrolls the least it can and stops between entries, so the reveal lands on a boundary.
        requestSelectionReveal()
        Self.logger.debug(
            """
            selectionDidChange rail=\(self.railName, privacy: .public) row=\(row, privacy: .public) \
            highlight=\(Self.describe(self.entries[row].workspace), privacy: .private(mask: .hash))
            """
        )
    }
}
