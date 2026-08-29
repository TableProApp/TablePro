//
//  WorkspaceRailViewController.swift
//  TablePro
//

import AppKit
import Combine
import Observation
import os
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
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WorkspaceRail")
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
    private let activationObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)
    private let scrollObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)
    private var contentTopConstraint: NSLayoutConstraint?

    /// A scroll is settled once it has stopped changing, which is the only signal every input
    /// device gives. `NSScrollViewWillStartLiveScroll`/`DidEndLiveScroll` would be the obvious pair,
    /// and `NSScrollView.h` says outright that a legacy mouse is not bracketed by them, which is the
    /// device most likely to leave the strip resting mid-tile.
    private var scrollSettle: DispatchWorkItem?

    /// A reorder scrolls the strip itself as the pointer nears an edge, so settling during one would
    /// fight the drag it is reacting to.
    private var isReordering = false

    private var needsSelectionReveal = false

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
        tableView.intercellSpacing = NSSize(width: 0, height: layout.rowSpacing)
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
        /// The bottom inset is the rail's own, and `contentInsets` and the automatic flag are one
        /// property: writing the inset clears the flag anyway, so it is cleared here where it can be
        /// read. Nothing is given up, because the automatic inset reads the scroll view's own safe
        /// area, which `pinContentBelowTitleBar` has already reduced to nothing.
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

    /// Re-armed on every bounds change, so the strip settles once the scrolling stops rather than
    /// once per frame of it. Settling itself changes the bounds, which comes back through here and
    /// finds nothing left to do.
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
        let settled = WorkspaceRailScrollGeometry.settledOrigin(
            proposed: clipView.bounds.origin.y,
            selectedRow: entries.indices.contains(tableView.selectedRow) ? tableView.selectedRow : nil,
            rowCount: entries.count,
            rowPitch: layout.rowPitch,
            rowHeight: layout.rowHeight,
            viewportHeight: clipView.bounds.height
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

    /// Recomputed rather than set once, because the row count, the row height and the viewport all
    /// move: an entry opens or closes, the sidebar icon size changes, the window resizes.
    private func applyBottomInset() {
        let clipView = scrollView.contentView
        let inset = WorkspaceRailScrollGeometry.bottomInset(
            rowCount: entries.count,
            rowPitch: layout.rowPitch,
            rowHeight: layout.rowHeight,
            documentHeight: tableView.frame.height,
            viewportHeight: clipView.bounds.height
        )
        guard abs(scrollView.contentInsets.bottom - inset) > 0.5 else { return }
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
    }

    /// Asked for when the highlight moves, and held until the strip has a viewport to move inside.
    ///
    /// The rail is laid out after `viewDidLoad` has already applied the first selection, so the
    /// clip view can still be zero high when the entry to show is below the fold. Nothing arrives
    /// later to say so: `NSView.boundsDidChangeNotification` is not posted for a bounds change that
    /// came from the frame resizing, and `NSTableView` does not reveal a selection it already holds.
    private func requestSelectionReveal() {
        needsSelectionReveal = true
        revealSelectedRowIfNeeded()
    }

    private func revealSelectedRowIfNeeded() {
        guard needsSelectionReveal, scrollView.contentView.bounds.height > 0 else { return }
        needsSelectionReveal = false
        revealSelectedRow()
    }

    /// Silent while the entry is already whole and on screen. Every rail lists every workspace, so
    /// one window's change reloads all of them; the callers are the paths where the highlight
    /// actually moved, so a strip whose own entry did not change stays where its window left it.
    private func revealSelectedRow() {
        let clipView = scrollView.contentView
        guard let origin = WorkspaceRailScrollGeometry.revealOrigin(
            row: tableView.selectedRow,
            rowCount: entries.count,
            rowPitch: layout.rowPitch,
            rowHeight: layout.rowHeight,
            viewportHeight: clipView.bounds.height,
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

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
        applyBottomInset()
        revealSelectedRowIfNeeded()
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
        applyBottomInset()
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
        tableView.intercellSpacing = NSSize(width: 0, height: layout.rowSpacing)
        tableView.sizeLastColumnToFit()
        tableView.reloadData()
        applyBottomInset()
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
        let previousSelection = appliedSelection
        appliedSelection = entries[row].workspace
        Self.logger.debug(
            """
            applySelection rail=\(self.railName, privacy: .public) \
            browsed=\(browsed.map(Self.describe) ?? "none", privacy: .public) \
            row=\(row, privacy: .public) applied=\(Self.describe(self.entries[row].workspace), privacy: .public)
            """
        )
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard previousSelection != appliedSelection else { return }
        requestSelectionReveal()
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

    /// Close means the entry highlighted here while the strip holds the keyboard, and the
    /// connection when that entry is the only one it has.
    ///
    /// The selector is the window's, deliberately: `performClose:` reaching the responder chain
    /// finds this implementation before the window's whenever the strip is focused, which is the
    /// same mechanism that gives Cut and Copy a different meaning in each view. The window used to
    /// ask whether the strip had focus and branch on the answer, which is this rule written out by
    /// hand.
    @objc
    internal func performClose(_ sender: Any?) {
        guard let workspace = appliedSelection else {
            /// Nothing highlighted means the strip has no entry to close, not that Close does
            /// nothing: swallowing it here would leave the command dead in a window that has tabs,
            /// which is the failure this whole route exists to prevent.
            view.window?.performClose(sender)
            return
        }
        close(workspace)
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
    /// One path, whichever window owns the entry. Selecting the connection in its own window comes
    /// first and always: the cross-window case used to raise the target window and move the target
    /// connection's browse cursor without ever telling that window to show it, so it came forward
    /// still showing the connection it had, its tabs and toolbar named that one, and the work the
    /// user clicked moved silently behind it.
    ///
    /// It ends at `applySelection`, which reads this window's own selection back: a workspace this
    /// window hosts leaves the highlight on the row the user picked; one belonging to another window
    /// leaves it where it was, because this window did not move.
    private func activate(_ workspace: WorkspaceID) {
        guard let window = WindowManager.shared.window(for: workspace.connectionId),
              let target = window.contentViewController as? MainSplitViewController else {
            Self.logger.error(
                "activate has no window target=\(Self.describe(workspace), privacy: .public)"
            )
            return
        }

        target.selectHostedConnection(workspace.connectionId)

        guard window !== view.window else {
            moveBrowseCursor(of: window, to: workspace)
            applySelection()
            return
        }

        let group = window.tabGroup
        Self.logger.info(
            """
            activate rail=\(self.railName, privacy: .public) \
            target=\(Self.describe(workspace), privacy: .public) \
            window=\(window.windowNumber, privacy: .public) visible=\(window.isVisible, privacy: .public) \
            tabs=\(group?.windows.count ?? 0, privacy: .public) \
            wasSelectedTab=\(group?.selectedWindow === window, privacy: .public)
            """
        )

        /// A background tab is a window AppKit will happily make key without bringing to the
        /// front of its group, which reads as the click doing nothing. Selecting it in the
        /// group first is the documented way to raise a specific tab.
        if let group, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
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
        requestSelectionReveal()
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
    private func closeWorkspace(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceID else { return }
        close(workspace)
    }

    @objc
    private func closeConnection(_ sender: NSMenuItem) {
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

    /// Named after what the engine calls a container, not after the row. "Close “logs”" would read
    /// as the connection on the one key the app already uses for exactly that, and its translations
    /// say so: the Turkish for `Close “%@”` is "close %@'s connection".
    internal static func containerCloseTitle(for entry: WorkspaceRailEntry) -> String {
        let format = entry.containerTarget == .schema
            ? String(localized: "Close Schema “%@”")
            : String(localized: "Close Database “%@”")
        return String(format: format, entry.container)
    }

    /// Read from the entries this rail is showing, which is the list the user is looking at.
    private func closeScope(for workspace: WorkspaceID) -> WorkspaceCloseAction.Scope {
        guard !workspace.container.isEmpty else { return .connection }
        let count = entries.count { $0.workspace.connectionId == workspace.connectionId }
        return WorkspaceCloseAction.scope(entryCount: count)
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
    /// The strip's own contextual menu names what it would close, and the menu bar has to agree with
    /// it word for word: the command is the same one, so an entry that is its connection's only one
    /// reads "Close Connection" in both, because that is what closing it takes.
    /// nil while nothing is highlighted, so the resolver falls back to the window, which is where
    /// the command goes in that state too.
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
        /// The arrow keys move the highlight through `NSTableView` itself, which reveals the row it
        /// lands on by scrolling the least it can and so stops between entries. Landing on the
        /// boundary here keeps the strip from having to slide again once the scroll settles.
        requestSelectionReveal()
        Self.logger.debug(
            """
            selectionDidChange rail=\(self.railName, privacy: .public) row=\(row, privacy: .public) \
            highlight=\(Self.describe(self.entries[row].workspace), privacy: .public)
            """
        )
    }
}
