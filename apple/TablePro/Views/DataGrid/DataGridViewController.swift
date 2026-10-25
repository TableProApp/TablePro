//
//  DataGridViewController.swift
//  TablePro
//

import AppKit
import Combine

// An NSViewController so commitEditing() and discardEditing() are NSEditor's own (probe P1h).
@MainActor
final class DataGridViewController: NSViewController, DataGridMountedView {
    private(set) var model: DataGridModel
    let presenter: DataGridCellPresenter
    let container = DataGridContainerView()
    let editingState = DataGridEditingState()
    let menuState = DataGridMenuState()

    private(set) lazy var selectionSummaryTracker = SelectionSummaryTracker(
        inputProvider: { [weak self] in self?.selectionSummaryInput() }
    )

    var isMirroringSelection = false
    var isApplyingSortDescriptors = false
    var isRebuildingColumns = false
    var pendingHeaderPress: (kind: DataGridPane.Kind, identifier: NSUserInterfaceItemIdentifier)?
    var drawnSelection: GridSelection = .empty
    var effectiveFrozenCount = 0
    var resultColumnIDs: [DataGridColumnID] = []
    var knownWidths: [DataGridColumnID: CGFloat] = [:]
    var knownWidthsSawRows = false
    var savedWidthIDs: Set<DataGridColumnID> = []
    var accessibilityMountedRows = NSRange(location: 0, length: 0)
    var needsViewportRestore = false
    var pendingFocus = false
    var lastDataGridSettings = AppSettingsManager.shared.dataGrid
    var prewarmTask: Task<Void, Never>?
    var prewarmResumeTask: Task<Void, Never>?
    var reorderToolTipOwner: NSString?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var themeCancellable: AnyCancellable?
    private var findCancellable: AnyCancellable?
    private var drawnFindMatch: GridFindState.Match?

    init(model: DataGridModel) {
        self.model = model
        presenter = DataGridCellPresenter(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var main: DataGridPane { container.main }
    var frozen: DataGridPane { container.frozen }
    var panes: [DataGridPane] { container.panes }
    var gridHasFocus: Bool { container.gridHasFocus }

    // MARK: - Lifecycle

    override func loadView() {
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        container.controller = self
        for pane in panes {
            pane.tableView.controller = self
            pane.tableView.delegate = self
            pane.tableView.dataSource = self
            let menu = NSMenu()
            menu.delegate = self
            pane.tableView.menu = menu
            pane.tableView.setDraggingSourceOperationMask(.move, forLocal: true)
            pane.tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        }
        observeEnvironment()
        mount()
    }

    private func mount() {
        model.attach(self)
        presenter.registry.adopt(model.themeScope, in: view.effectiveAppearance)
        observeTheme()
        observeFind()
        applyTableSettings()
        reloadAll()
        needsViewportRestore = model.store.viewportAnchor != nil
        // Attaching publishes the summary state, which SwiftUI refuses inside the update that made this view.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.mountedView === self else { return }
            self.selectionSummaryTracker.attach(self.model.selectionSummary)
        }
    }

    // A representable kept across a model swap moves the grid to the new model instead of rebuilding.
    func adopt(_ newModel: DataGridModel) {
        guard newModel !== model else { return }
        _ = commitCellEditing()
        saveViewportAnchor()
        model.detach(self)
        model = newModel
        presenter.adopt(newModel)
        drawnSelection = .empty
        resultColumnIDs = []
        knownWidths = [:]
        knownWidthsSawRows = false
        savedWidthIDs = []
        mount()
    }

    // A new mount of the same model can arrive before this one goes, so only the current mount writes the anchor.
    func dismantle() {
        _ = commitCellEditing()
        dismissValueFilterPopover()
        if model.mountedView === self {
            saveViewportAnchor()
        }
        model.detach(self)
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        cancellables.removeAll()
        themeCancellable = nil
        findCancellable = nil
        selectionSummaryTracker.cancel()
        selectionSummaryTracker.attach(nil)
        container.tearDown()
    }

    func containerDidMoveToWindow() {
        guard view.window != nil else { return }
        if pendingFocus {
            pendingFocus = false
            focus()
        }
        container.refreshFocus()
    }

    func containerDidLayout() {
        if resolveEffectiveFrozenCount() != effectiveFrozenCount {
            updateFrozenPane()
            redrawVisibleRows()
        }
        updateReorderToolTip()
        if needsViewportRestore, main.scrollView.contentView.bounds.height > 0 {
            needsViewportRestore = false
            applyStagedViewport()
        }
    }

    // MARK: - DataGridMountedView

    var isEditing: Bool { isEditingCell }

    @discardableResult
    func beginEditing(row: Int, displayColumn: Int) -> Bool {
        beginEditingCell(row: row, displayColumn: displayColumn)
    }

    override func commitEditing() -> Bool {
        commitCellEditing()
    }

    override func discardEditing() {
        discardCellEditing()
    }

    @discardableResult
    func focus() -> Bool {
        guard let window = view.window else {
            pendingFocus = true
            return false
        }
        return window.makeFirstResponder(main.tableView)
    }

    func gridFocusDidChange() {
        let hasFocus = gridHasFocus
        for pane in panes {
            pane.tableView.enumerateAvailableRowViews { rowView, _ in
                rowView.isEmphasized = hasFocus
                (rowView as? DataGridRowView)?.redrawCells()
            }
        }
    }

    // MARK: - Environment

    private func observeEnvironment() {
        AppEvents.shared.dataGridSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.dataGridSettingsDidChange() }
            .store(in: &cancellables)
        AppEvents.shared.systemTimeZoneChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reformatText() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        // Deferred off the accessibility query that raised the flag: rebuilding rows inside it re-enters AppKit's walk.
        observers.append(center.addObserver(forName: DataGridAccessibility.didActivateNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.remountAccessibilityCells() }
        })
        let scrollView = main.scrollView
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pausePrewarm() }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePrewarmResume() }
        })
    }

    // objectWillChange fires before the value moves, so the current match is read on the next turn.
    private func observeFind() {
        drawnFindMatch = model.find.currentMatch
        findCancellable = model.find.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.findStateDidChange() }
        }
    }

    private func findStateDidChange() {
        let match = model.find.currentMatch
        guard match != drawnFindMatch else { return }
        let rows = IndexSet([drawnFindMatch, match].compactMap { $0.flatMap { model.displayIndex(of: $0.rowID) } })
        drawnFindMatch = match
        redrawRows(rows)
    }

    private func observeTheme() {
        themeCancellable = model.themeScope.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.themeDidChange() }
    }

    // Also fires for Accent, Highlight, Increase Contrast and the grid font, none of which moves a value: repaint, never reload.
    func themeDidChange() {
        presenter.registry.preparePalette(in: view.effectiveAppearance)
        for pane in panes {
            DataGridBodyChrome.applyThemeColors(to: pane.tableView, scope: model.themeScope)
            pane.headerView.needsDisplay = true
        }
        applyRowHeight()
        applyRowNumberWidth()
        refreshHeaders()
        redrawVisibleRows()
    }

    private func dataGridSettingsDidChange() {
        let settings = AppSettingsManager.shared.dataGrid
        let previous = lastDataGridSettings
        lastDataGridSettings = settings
        presenter.registry.reloadSettings(settings)
        applyRowHeight()
        if previous.showAlternateRows != settings.showAlternateRows {
            panes.forEach { $0.tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows }
            panes.forEach { $0.tableView.needsDisplay = true }
            redrawVisibleRows()
        }
        if previous.defaultSortDirection != settings.defaultSortDirection {
            reconcileColumns()
        }
        if previous.dateFormat != settings.dateFormat
            || previous.nullDisplay != settings.nullDisplay
            || previous.enableSmartValueDetection != settings.enableSmartValueDetection {
            reformatText()
        } else if previous.showInvisibleCharacters != settings.showInvisibleCharacters {
            redrawVisibleRows()
        }
    }

    // Rebuilds every formatted string: the date format, NULL text or smart detection moved, or the Mac's time zone did.
    func reformatText() {
        model.display.cache.removeAll()
        redrawVisibleRows()
        startBackgroundPrewarm()
    }

    func applyTableSettings() {
        if presenter.registry.scope !== model.themeScope {
            presenter.registry.adopt(model.themeScope, in: view.effectiveAppearance)
            observeTheme()
        }
        let configuration = model.configuration
        let settings = AppSettingsManager.shared.dataGrid
        for pane in panes {
            let table = pane.tableView
            DataGridBodyChrome.applyThemeColors(to: table, scope: model.themeScope)
            table.usesAlternatingRowBackgroundColors = settings.showAlternateRows
            table.toolTip = configuration.isEditable ? nil : configuration.editRefusalMessage
            applyRowReorder(configuration.rowReorder, to: table)
        }
        main.tableView.setAccessibilityLabel(configuration.accessibilityLabel ?? String(localized: "Data grid"))
        applyRowHeight()
    }

    private func applyRowReorder(_ reorder: DataGridRowReorder, to table: DataGridTableView) {
        let hasType = table.registeredDraggedTypes.contains(Self.rowDragType)
        if reorder.isEnabled, !hasType {
            table.registerForDraggedTypes([Self.rowDragType])
            table.draggingDestinationFeedbackStyle = .regular
        } else if !reorder.isEnabled, hasType {
            let remaining = table.registeredDraggedTypes.filter { $0 != Self.rowDragType }
            table.unregisterDraggedTypes()
            if !remaining.isEmpty {
                table.registerForDraggedTypes(remaining)
            }
        }
    }

    static let rowDragType = NSPasteboard.PasteboardType("com.TablePro.rowDrag")

    // The row number is the handle a reorder drag starts from, so it carries the reason a drag is withheld.
    func updateReorderToolTip() {
        let table = frozen.tableView
        table.removeAllToolTips()
        reorderToolTipOwner = nil
        guard let reason = model.configuration.rowReorder.unavailableReason, frozen.hasRowNumberColumn else { return }
        let owner = reason as NSString
        reorderToolTipOwner = owner
        _ = table.addToolTip(table.rect(ofColumn: 0), owner: owner, userData: nil)
    }

    // MARK: - Rows

    func redrawVisibleRows() {
        for pane in panes {
            pane.tableView.enumerateAvailableRowViews { rowView, _ in
                (rowView as? DataGridRowView)?.redrawCells()
            }
        }
    }

    // Only rows AppKit holds a view for can need a repaint, so a select-all over a large result costs the prepared rows.
    func redrawRows(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        for pane in panes {
            pane.tableView.enumerateAvailableRowViews { rowView, row in
                guard rows.contains(row) else { return }
                (rowView as? DataGridRowView)?.redrawCells()
            }
        }
    }

    func rowTint(forRow row: Int) -> NSColor? {
        let rows = model.rows
        guard let rowModel = model.order.row(at: row, in: rows) else { return nil }
        presenter.prepareRowState(rows: rows)
        return presenter.visualState(of: rowModel).tint(in: model.themeScope)
    }

    // MARK: - Selection summary

    // Nil while fewer than two cells are selected, which is when the grid reports no summary.
    private func selectionSummaryInput() -> SelectionSummaryInput? {
        let selection = model.selection
        guard selection.hasMultipleCells else { return nil }
        let rows = model.rows
        let changeState = model.changeState
        let policy = model.dataSource?.gridSummaryColumnPolicy() ?? .derived(
            columnTypes: rows.columnTypes,
            displayFormats: model.store.displayFormats,
            columnCount: rows.columns.count
        )
        return SelectionSummaryInput(
            selection: selection,
            tableRows: rows,
            displayIDs: model.order.filteredIDs,
            dataColumnsByDisplayPosition: model.columns.columns.map(\.dataIndex),
            policy: policy,
            deletedRowIDs: changeState?.deletedRowIDs ?? [],
            insertedRowIDs: changeState?.insertedRowIDs ?? [],
            modifiedCells: changeState?.modifiedCells ?? [:]
        )
    }
}
