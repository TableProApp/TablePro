//
//  ConnectionNavigatorViewController.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProConnectionLibrary

/// The navigator's list. Return opens, Escape clears the filter, and a click takes the keyboard.
///
/// Not a `SidebarOutlineView`: that class takes the keyboard whenever its window has no first
/// responder, and this list sits in a column that can be collapsed, where taking it would put the
/// keyboard in a list nobody can see.
internal final class ConnectionNavigatorOutlineView: NSOutlineView {
    internal weak var navigator: ConnectionNavigatorViewController?

    /// Set the moment the column is told to hide. AppKit hides a collapsing split item only once its
    /// animation ends, and until then the list would still offer itself as a key view.
    internal var isColumnShown = true

    override internal var canBecomeKeyView: Bool {
        isColumnShown && super.canBecomeKeyView
    }

    override internal func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    /// `NSTableView` moves the selection for the arrow keys itself but never turns Return into
    /// `insertNewline(_:)`, so Return and Enter go through the key bindings, as the data grid's
    /// table sends them.
    override internal func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .carriageReturn?, .enter?, .newline?:
            interpretKeyEvents([event])
        default:
            super.keyDown(with: event)
        }
    }

    override internal func insertNewline(_ sender: Any?) {
        navigator?.activateSelection()
    }

    override internal func cancelOperation(_ sender: Any?) {
        navigator?.clearFilter()
    }
}

/// One outline row, kept across reloads by id so the outline's expansion and selection follow the
/// same group or connection, as `WelcomeOutlineItem` does.
internal final class ConnectionNavigatorOutlineItem: NSObject {
    internal let id: ConnectionNavigatorRowID
    internal var row: ConnectionNavigatorRow
    internal var children: [ConnectionNavigatorOutlineItem] = []

    internal init(row: ConnectionNavigatorRow) {
        self.id = row.id
        self.row = row
    }
}

internal final class ConnectionNavigatorCellView: SidebarHostingCellView<ConnectionNavigatorRowView> {}

/// Every saved connection in its groups, in the window's connections column.
///
/// AppKit on purpose, as the strip beside it and the Favorites outline are: a SwiftUI `List` cannot
/// draw an emphasized selection under a bare `NSHostingController`. The rows stay SwiftUI inside
/// source list cells, the way the sidebar's other lists draw theirs.
@MainActor
internal final class ConnectionNavigatorViewController: NSViewController, NSSearchFieldDelegate, NSMenuDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate {
    internal static let defaultWidth: CGFloat = 220
    internal static let minimumWidth: CGFloat = 180
    internal static let maximumWidth: CGFloat = 400

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ConnectionNavigatorCell")

    internal let model: ConnectionNavigatorModel
    internal let filterField = NSSearchField()
    internal let outlineView = ConnectionNavigatorOutlineView()
    internal var onWidthChange: (() -> Void)?

    internal var isColumnShown: Bool {
        get { outlineView.isColumnShown }
        set { outlineView.isColumnShown = newValue }
    }

    private var scrollView: NSScrollView?
    private let emptyState = NSStackView()
    private var items: [ConnectionNavigatorRowID: ConnectionNavigatorOutlineItem] = [:]
    private var rootItems: [ConnectionNavigatorOutlineItem] = []
    private var isApplyingExpansion = false
    private var isReloading = false
    private var reportedWidth: CGFloat = 0
    private var rowSizePreference = AppSettingsManager.shared.general.sidebarRowSize
    private var modelCancellables: Set<AnyCancellable> = []
    private var rowSizeObservation: AnyCancellable?
    private var groupSheet: NSViewController?

    internal init(model: ConnectionNavigatorModel = ConnectionNavigatorModel()) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionNavigatorViewController does not support NSCoder init")
    }

    // MARK: - View

    /// The frame's width is the one the column first opens at: a split item expanding for the first
    /// time takes its view's own width, and the autosaved width replaces it from then on.
    override internal func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 400))

        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.placeholderString = String(localized: "Filter Connections")
        filterField.controlSize = .regular
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self
        filterField.setAccessibilityIdentifier("connection-navigator-filter")
        filterField.setAccessibilityLabel(String(localized: "Filter Connections"))
        view.addSubview(filterField)

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "ConnectionNavigatorColumn",
                allowsMultipleSelection: false,
                rowSizePreference: rowSizePreference
            )
        )
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scrollView
        view.addSubview(scrollView)

        outlineView.navigator = self
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleClick)
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.setAccessibilityIdentifier("connection-navigator")
        outlineView.setAccessibilityLabel(String(localized: "Connections"))
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        configureEmptyState()

        /// Margins, not invariants: they yield rather than break while the column animates shut.
        let insets = [
            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
        ]
        for inset in insets {
            inset.priority = .defaultHigh
        }
        NSLayoutConstraint.activate(insets + [
            filterField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 5),
            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 10),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
        ])

        observeModel()
        observeRowSize()
        model.onOpenFailure = { [weak self] error in
            AlertHelper.showErrorSheet(
                title: String(localized: "Connection Failed"),
                message: error.localizedDescription,
                window: self?.view.window
            )
        }
    }

    private func configureEmptyState() {
        let title = NSTextField(labelWithString: String(localized: "No Saved Connections"))
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        let button = NSButton(
            title: String(localized: "New Connection…"),
            target: self,
            action: #selector(newConnectionFromEmptyState)
        )
        button.bezelStyle = .rounded
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.setViews([title, button], in: .center)
        emptyState.isHidden = true
        view.addSubview(emptyState)
    }

    /// The list comes back from wherever it was without knowing what it missed, so it reads the
    /// library again each time it appears.
    override internal func viewWillAppear() {
        super.viewWillAppear()
        model.start()
    }

    override internal func viewDidDisappear() {
        super.viewDidDisappear()
        model.stop()
    }

    /// Reported from here rather than from the split view's resize callback, which runs before the
    /// column has taken its new width.
    override internal func viewDidLayout() {
        super.viewDidLayout()
        guard view.frame.width != reportedWidth else { return }
        reportedWidth = view.frame.width
        onWidthChange?()
    }

    /// `@Published` sends before it stores, so these read the rows, which the model always writes
    /// before it moves either revision.
    private func observeModel() {
        model.$revision
            .dropFirst()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &modelCancellables)
        model.$presentationRevision
            .dropFirst()
            .sink { [weak self] _ in self?.refreshRows() }
            .store(in: &modelCancellables)
    }

    /// The navigator sits beside the object list, so it takes the same row size.
    private func observeRowSize() {
        rowSizeObservation = AppSettingsManager.shared.onMainActorChange { [weak self] in
            guard let self else { return }
            let current = AppSettingsManager.shared.general.sidebarRowSize
            guard current != self.rowSizePreference else { return }
            self.rowSizePreference = current
            if let scrollView = self.scrollView {
                SidebarOutlineScaffold.applyRowSize(current, to: scrollView)
            }
            self.reload()
        }
    }

    // MARK: - Reload

    private func reload() {
        guard isViewLoaded else { return }
        let previous = selectedRowID
        rebuildItems()
        isReloading = true
        outlineView.reloadData()
        applyExpansion()
        if let previous, row(for: previous) >= 0 {
            select(row(for: previous))
        } else {
            selectShownConnection()
        }
        isReloading = false
        applyEmptyState()
    }

    private func rebuildItems() {
        var used: Set<ConnectionNavigatorRowID> = []
        func item(for row: ConnectionNavigatorRow) -> ConnectionNavigatorOutlineItem {
            used.insert(row.id)
            let built = items[row.id] ?? ConnectionNavigatorOutlineItem(row: row)
            built.row = row
            built.children = row.children.map(item(for:))
            items[row.id] = built
            return built
        }
        rootItems = model.rows.map(item(for:))
        items = items.filter { used.contains($0.key) }
    }

    /// A status or a window moved: the same rows, marked differently.
    private func refreshRows() {
        guard isViewLoaded else { return }
        func update(_ rows: [ConnectionNavigatorRow]) {
            for row in rows {
                items[row.id]?.row = row
                update(row.children)
            }
        }
        update(model.rows)
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private func applyEmptyState() {
        let isEmpty = model.isLibraryEmpty
        emptyState.isHidden = !isEmpty
        scrollView?.isHidden = isEmpty
        filterField.isEnabled = !isEmpty
    }

    internal var isShowingEmptyState: Bool {
        !emptyState.isHidden
    }

    // MARK: - Expansion

    private func applyExpansion() {
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        applyExpansion(to: rootItems)
    }

    private func applyExpansion(to items: [ConnectionNavigatorOutlineItem]) {
        for item in items {
            guard case .group(let group) = item.row, !item.children.isEmpty else { continue }
            guard model.isGroupExpanded(group) else {
                outlineView.collapseItem(item)
                continue
            }
            outlineView.expandItem(item)
            applyExpansion(to: item.children)
        }
    }

    internal func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingExpansion,
              let item = notification.userInfo?["NSObject"] as? ConnectionNavigatorOutlineItem,
              case .group(let id) = item.id else { return }
        if !isReloading {
            model.setGroupExpanded(id, true)
        }
        /// A group the user opens shows its subgroups as they were left.
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        applyExpansion(to: item.children)
    }

    internal func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingExpansion, !isReloading,
              let item = notification.userInfo?["NSObject"] as? ConnectionNavigatorOutlineItem,
              case .group(let id) = item.id else { return }
        model.setGroupExpanded(id, false)
    }

    // MARK: - Selection

    private var selectedRowID: ConnectionNavigatorRowID? {
        (outlineView.item(atRow: outlineView.selectedRow) as? ConnectionNavigatorOutlineItem)?.id
    }

    /// The row index of a group or connection, or -1 when it is not listed or sits in a closed group.
    internal func row(for id: ConnectionNavigatorRowID) -> Int {
        guard let item = items[id] else { return -1 }
        return outlineView.row(forItem: item)
    }

    /// The window switched connection. The highlight follows it, and the rows' marks with it.
    internal func refreshSelection() {
        guard isViewLoaded else { return }
        model.refreshPresentation()
        selectShownConnection()
    }

    /// A connection the library does not hold, one opened from a file or a link, leaves nothing
    /// selected rather than a row that is not it.
    private func selectShownConnection() {
        guard let shown = model.shownConnectionId else {
            outlineView.deselectAll(nil)
            return
        }
        select(row(for: .connection(shown)))
    }

    private func select(_ row: Int) {
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - Actions

    @objc
    private func handleClick() {
        let clicked = outlineView.clickedRow
        guard clicked >= 0 else { return }
        model.handleClick(on: (outlineView.item(atRow: clicked) as? ConnectionNavigatorOutlineItem)?.id)
    }

    @objc
    private func handleDoubleClick() {
        let clicked = outlineView.clickedRow
        guard clicked >= 0, let item = outlineView.item(atRow: clicked) as? ConnectionNavigatorOutlineItem else { return }
        activate(item)
    }

    /// Return: a connection opens, a group opens or closes.
    internal func activateSelection() {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? ConnectionNavigatorOutlineItem else { return }
        activate(item)
    }

    private func activate(_ item: ConnectionNavigatorOutlineItem) {
        switch item.id {
        case .group:
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        case .connection(let id):
            Task { await model.open(id) }
        }
    }

    internal func clearFilter() {
        filterField.stringValue = ""
        model.filterText = ""
    }

    internal func focusFilter() {
        guard filterField.isEnabled else { return }
        view.window?.makeFirstResponder(filterField)
    }

    /// Find, while the keyboard is in the column, means the column's own filter. This controller is
    /// ahead of the window's in the responder chain only while that is so.
    @objc
    internal func performFind(_ sender: Any?) {
        focusFilter()
    }

    @objc
    private func newConnectionFromEmptyState() {
        model.perform(.newConnection, presentingWindow: view.window)
    }

    // MARK: - Filter

    internal func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === filterField else { return }
        model.filterText = filterField.stringValue
    }

    internal func searchFieldDidEndSearching(_ sender: NSSearchField) {
        model.filterText = ""
    }

    /// Down arrow carries the keyboard from the field into the list, as the sidebar's filter does.
    internal func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.moveDown(_:)), outlineView.numberOfRows > 0 else { return false }
        view.window?.makeFirstResponder(outlineView)
        if outlineView.selectedRow < 0 {
            select(0)
        }
        return true
    }

    // MARK: - Menu

    internal func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = outlineView.clickedRow
        let id = clicked >= 0 ? (outlineView.item(atRow: clicked) as? ConnectionNavigatorOutlineItem)?.id : nil
        SidebarMenuBuilder.fill(
            menu,
            with: ConnectionNavigatorMenu.sections(for: model.menuTarget(for: id)),
            target: self,
            action: #selector(performNavigatorMenuCommand(_:))
        )
    }

    /// Named for the navigator: an `@objc` action sits in the responder chain, and a name the menu
    /// bar also sends with no target would be taken here.
    @objc
    private func performNavigatorMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarMenuCommandBox<ConnectionNavigatorCommand> else { return }
        guard case .newGroup(let parentId) = box.command else {
            model.perform(box.command, presentingWindow: view.window)
            return
        }
        presentNewGroupSheet(parentId: parentId)
    }

    /// The group sheet the Welcome window uses, saving through the same store. SwiftUI's `dismiss`
    /// does not reach a sheet AppKit presents, so the sheet closes through the controller kept here.
    internal func presentNewGroupSheet(parentId: UUID?) {
        guard groupSheet == nil else { return }
        let sheet = GroupEditorSheet(
            mode: .create(parentId: parentId),
            groups: model.groups,
            onDismiss: { [weak self] in self?.dismissGroupSheet() },
            onSave: { [weak self] draft in try self?.model.createGroup(draft) }
        )
        let controller = NSHostingController(rootView: sheet)
        groupSheet = controller
        presentAsSheet(controller)
    }

    private func dismissGroupSheet() {
        guard let groupSheet else { return }
        self.groupSheet = nil
        dismiss(groupSheet)
    }

    // MARK: - Data Source

    internal func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    internal func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    internal func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? ConnectionNavigatorOutlineItem)?.children.isEmpty ?? true)
    }

    private func children(of item: Any?) -> [ConnectionNavigatorOutlineItem] {
        guard let item = item as? ConnectionNavigatorOutlineItem else { return rootItems }
        return item.children
    }

    // MARK: - Delegate

    internal func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? ConnectionNavigatorOutlineItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? ConnectionNavigatorCellView
            ?? makeCell()
        cell.update(rootView: ConnectionNavigatorRowView(row: item.row, rowSizePreference: rowSizePreference))
        return cell
    }

    private func makeCell() -> ConnectionNavigatorCellView {
        let cell = ConnectionNavigatorCellView()
        cell.identifier = Self.cellIdentifier
        return cell
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        item: Any
    ) -> String? {
        switch (item as? ConnectionNavigatorOutlineItem)?.row {
        case .group(let group): return group.name
        case .connection(let connection): return connection.connection.name
        case nil: return nil
        }
    }
}
