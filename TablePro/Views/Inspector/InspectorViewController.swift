//
//  InspectorViewController.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

@MainActor
final class InspectorViewController: NSViewController, NSUserInterfaceValidations {
    private weak var nsDocument: NSDocument?
    private weak var inspectorDocument: (any InspectorDocument)?
    private let changeManager: AnyChangeManager
    private let inspectorChangeManager: InspectorChangeManager
    private let state: InspectorViewState
    private let gridDelegate: InspectorGridDelegate

    private var displayToStore: [Int] = []
    private var displayIndices: [Int]?
    private var isApplyingGridCellEdit = false
    private var gridReloadScheduled = false
    private var filterDebounceTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    private var lastFilterClauses: [FilterClause] = []
    private var lastSortSpecs: [SortSpec] = []
    private var pendingPostRefresh: PostRefreshAction?

    private enum PostRefreshAction {
        case selectClamped(displayRow: Int)
        case focusStoreIndex(Int)
    }

    init(nsDocument: NSDocument, inspectorDocument: any InspectorDocument) {
        self.nsDocument = nsDocument
        self.inspectorDocument = inspectorDocument
        self.inspectorChangeManager = InspectorChangeManager()
        self.changeManager = AnyChangeManager(inspectorChangeManager)
        self.state = InspectorViewState()
        self.gridDelegate = InspectorGridDelegate()
        super.init(nibName: nil, bundle: nil)
        gridDelegate.owner = self
        state.pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        inspectorDocument.onChange = { [weak self] in
            guard let self else { return }
            if self.isApplyingGridCellEdit, self.displayIndices == nil {
                return
            }
            self.recomputeDisplay()
        }
        NotificationCenter.default.addObserver(
            forName: .inspectorDocumentDidRevert,
            object: nsDocument,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recomputeDisplay()
            }
        }
        recomputeDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let rootView = InspectorRootView(
            state: state,
            changeManager: changeManager,
            delegate: gridDelegate,
            onFilterChanged: { [weak self] in self?.scheduleFilterRecompute() },
            onPreviousPage: { [weak self] in self?.goToPage(offsetBy: -1) },
            onNextPage: { [weak self] in self?.goToPage(offsetBy: 1) }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    // MARK: - Grid delegate handlers

    fileprivate func handleCellEdit(displayRow: Int, column: Int, newValue: String?) {
        guard displayRow >= 0, displayRow < displayToStore.count else { return }
        let storeRow = displayToStore[displayRow]
        isApplyingGridCellEdit = true
        defer { isApplyingGridCellEdit = false }
        inspectorDocument?.setCell(row: storeRow, column: column, to: newValue ?? "")
    }

    fileprivate func handleAddRow() {
        guard let inspectorDocument else { return }
        let newRowStoreIndex = inspectorDocument.rowCount
        pendingPostRefresh = .focusStoreIndex(newRowStoreIndex)
        inspectorDocument.appendRow()
    }

    fileprivate func handleCopyRows(_ displayIndices: Set<Int>) {
        guard let inspectorDocument else { return }
        let columnCount = inspectorDocument.columnNames.count
        let sortedDisplay = displayIndices.sorted()
        var lines: [String] = []
        lines.reserveCapacity(sortedDisplay.count)
        for displayRow in sortedDisplay {
            guard displayRow >= 0, displayRow < displayToStore.count else { continue }
            let storeRow = displayToStore[displayRow]
            let cells = (0..<columnCount).map { column -> String in
                inspectorDocument.value(row: storeRow, column: column)
                    .replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }
            lines.append(cells.joined(separator: "\t"))
        }
        guard !lines.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    fileprivate func handlePasteRows() {
        guard let inspectorDocument else { return }
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }
        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        var rows: [[String]] = []
        rows.reserveCapacity(lines.count)
        for line in lines {
            let fields = line.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\t" })
                .map { String($0) }
            if fields.count == 1, fields[0].isEmpty { continue }
            rows.append(fields)
        }
        guard !rows.isEmpty else { return }

        let undoManager = nsDocument?.undoManager
        undoManager?.beginUndoGrouping()
        for row in rows {
            let newRowIndex = inspectorDocument.rowCount
            inspectorDocument.appendRow()
            for (column, value) in row.enumerated() {
                inspectorDocument.setCell(row: newRowIndex, column: column, to: value)
            }
        }
        undoManager?.setActionName(String(localized: "Paste"))
        undoManager?.endUndoGrouping()
    }

    fileprivate func handleDeleteRows(_ displayIndexSet: Set<Int>) {
        guard let inspectorDocument else { return }
        let sortedDisplay = displayIndexSet.sorted()
        let storeIndices = sortedDisplay.compactMap { index -> Int? in
            guard index >= 0, index < displayToStore.count else { return nil }
            return displayToStore[index]
        }
        guard !storeIndices.isEmpty else { return }
        let columnCount = inspectorDocument.columnNames.count
        let rowsCells = storeIndices.map { storeRow in
            (0..<columnCount).map { inspectorDocument.value(row: storeRow, column: $0) }
        }
        let firstDisplayRow = sortedDisplay.first ?? 0
        InspectorDeleteConfirmation.confirmDeleteRowsIfNeeded(
            rowsCells: rowsCells,
            window: view.window
        ) { [weak self] in
            guard let self else { return }
            self.pendingPostRefresh = .selectClamped(displayRow: firstDisplayRow)
            self.inspectorDocument?.removeRows(at: IndexSet(storeIndices))
        }
    }

    fileprivate func handleSortChanged(_ newState: SortState) {
        state.sortState = newState
        recomputeDisplay()
    }

    fileprivate func handleUndo() {
        nsDocument?.undoManager?.undo()
    }

    fileprivate func handleRedo() {
        nsDocument?.undoManager?.redo()
    }

    private func goToPage(offsetBy delta: Int) {
        let newOffset = state.pageOffset + delta * state.pageSize
        guard newOffset >= 0, newOffset < max(state.visibleRowCount, 1) else { return }
        state.pageOffset = newOffset
        state.selectedRowIndices = []
        refreshVisiblePage()
    }

    private func applyViewIdentity(filter: [FilterClause], sort: [SortSpec]) {
        if filter != lastFilterClauses || sort != lastSortSpecs {
            state.selectedRowIndices = []
            lastFilterClauses = filter
            lastSortSpecs = sort
        }
    }

    // MARK: - Responder-chain actions

    @objc func undo(_ sender: Any?) { handleUndo() }
    @objc func redo(_ sender: Any?) { handleRedo() }
    @objc func saveDocument(_ sender: Any?) { nsDocument?.save(sender) }
    @objc func saveDocumentAs(_ sender: Any?) { nsDocument?.saveAs(sender) }
    @objc func inspectorAddRow(_ sender: Any?) { handleAddRow() }
    @objc func inspectorDeleteSelectedRows(_ sender: Any?) {
        handleDeleteRows(state.selectedRowIndices)
    }

    @objc func inspectorToggleHeaderRow(_ sender: Any?) {
        inspectorDocument?.toggleHeaderRow()
    }

    @objc func inspectorInsertRowAbove(_ sender: Any?) {
        performInsertRow(anchoredBy: sender, below: false)
    }

    @objc func inspectorInsertRowBelow(_ sender: Any?) {
        performInsertRow(anchoredBy: sender, below: true)
    }

    private func performInsertRow(anchoredBy sender: Any?, below: Bool) {
        guard let inspectorDocument else { return }
        let storeIndex = insertStoreIndex(anchoredBy: sender, below: below)
        pendingPostRefresh = .focusStoreIndex(storeIndex)
        inspectorDocument.insertRow(at: storeIndex)
    }

    private func insertStoreIndex(anchoredBy sender: Any?, below: Bool) -> Int {
        let anchorDisplayRow: Int? = if let item = sender as? NSMenuItem {
            item.tag
        } else if below {
            state.selectedRowIndices.max()
        } else {
            state.selectedRowIndices.min()
        }
        return InspectorRowInsertion.storeIndex(
            anchorDisplayRow: anchorDisplayRow,
            below: below,
            displayToStore: displayToStore,
            rowCount: inspectorDocument?.rowCount ?? 0
        )
    }

    @objc func inspectorAddColumn(_ sender: Any?) {
        promptForColumnName(title: String(localized: "Add Column"), initial: "") { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.inspectorDocument?.appendColumn(name: name)
            if self.state.columnLayout.columnOrder != nil {
                self.state.columnLayout.columnOrder?.append(name)
            }
        }
    }

    @objc func inspectorRenameColumn(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let inspector = inspectorDocument,
              menuItem.tag >= 0, menuItem.tag < inspector.columnNames.count else { return }
        let column = menuItem.tag
        let current = inspector.columnNames[column]
        promptForColumnName(title: String(localized: "Rename Column"), initial: current) { [weak self] name in
            guard let self, let name, !name.isEmpty, name != current else { return }
            self.inspectorDocument?.renameColumn(at: column, to: name)
            self.renameLayoutKey(from: current, to: name)
        }
    }

    @objc func inspectorInsertColumnLeft(_ sender: Any?) {
        performInsertColumn(anchoredBy: sender, toRight: false)
    }

    @objc func inspectorInsertColumnRight(_ sender: Any?) {
        performInsertColumn(anchoredBy: sender, toRight: true)
    }

    private func performInsertColumn(anchoredBy sender: Any?, toRight: Bool) {
        guard let inspector = inspectorDocument,
              let anchorIndex = columnInsertAnchor(from: sender, toRight: toRight) else { return }
        let anchorName = inspector.columnNames[anchorIndex]
        let insertIndex = toRight ? anchorIndex + 1 : anchorIndex
        promptForColumnName(title: String(localized: "Insert Column"), initial: "") { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.inspectorDocument?.insertColumn(at: insertIndex, name: name)
            self.insertLayoutKey(name, relativeTo: anchorName, after: toRight)
        }
    }

    private func columnInsertAnchor(from sender: Any?, toRight: Bool) -> Int? {
        guard let inspector = inspectorDocument else { return nil }
        let clicked = (sender as? NSMenuItem).map(\.tag)
        return InspectorColumnTargets.insertAnchor(
            clicked: clicked,
            fullySelected: selectedFullColumns(),
            columnCount: inspector.columnNames.count,
            toRight: toRight
        )
    }

    @objc func inspectorDeleteColumn(_ sender: Any?) {
        let columns = columnDeleteTargets(from: sender)
        performDeleteColumns(columns)
    }

    private func columnDeleteTargets(from sender: Any?) -> [Int] {
        guard let inspector = inspectorDocument else { return [] }
        return InspectorColumnTargets.deleteTargets(
            explicit: (sender as? NSMenuItem)?.representedObject as? [Int],
            fullySelected: selectedFullColumns(),
            columnCount: inspector.columnNames.count
        )
    }

    private func selectedFullColumns() -> IndexSet {
        gridDelegate.coordinator?.selectionController.selectedFullColumns() ?? IndexSet()
    }

    private func performDeleteColumns(_ columns: [Int]) {
        guard let inspector = inspectorDocument, !columns.isEmpty else { return }
        let containsData = columnsContainData(columns, inspector: inspector)
        InspectorDeleteConfirmation.confirmDeleteColumnsIfNeeded(
            count: columns.count,
            containsData: containsData,
            window: view.window
        ) { [weak self] in
            self?.deleteColumns(columns)
        }
    }

    private func deleteColumns(_ columns: [Int]) {
        guard let inspector = inspectorDocument else { return }
        let undoManager = nsDocument?.undoManager
        undoManager?.beginUndoGrouping()
        for column in columns.sorted(by: >) where column >= 0 && column < inspector.columnNames.count {
            let name = inspector.columnNames[column]
            inspector.removeColumn(at: column)
            removeLayoutKey(name)
        }
        undoManager?.setActionName(
            columns.count > 1 ? String(localized: "Delete Columns") : String(localized: "Delete Column")
        )
        undoManager?.endUndoGrouping()
    }

    private func columnsContainData(_ columns: [Int], inspector: any InspectorDocument) -> Bool {
        let rowCount = inspector.rowCount
        for column in columns {
            var row = 0
            while row < rowCount {
                if !inspector.value(row: row, column: column).isEmpty { return true }
                row += 1
            }
        }
        return false
    }

    @objc func inspectorSplitColumn(_ sender: Any?) {
        guard let column = structuralTargetColumn(from: sender) else { return }
        promptSplitColumn(column)
    }

    @objc func inspectorMergeColumns(_ sender: Any?) {
        guard let inspector = inspectorDocument,
              let column = structuralTargetColumn(from: sender),
              column + 1 < inspector.columnNames.count else { return }
        promptMergeColumns(column)
    }

    private func structuralTargetColumn(from sender: Any?) -> Int? {
        guard let inspector = inspectorDocument, !inspector.columnNames.isEmpty else { return nil }
        let count = inspector.columnNames.count
        if let menuItem = sender as? NSMenuItem, menuItem.tag >= 0, menuItem.tag < count {
            return menuItem.tag
        }
        if let first = gridDelegate.coordinator?.selectionController.selection.affectedColumns.min(),
           first >= 0, first < count {
            return first
        }
        return nil
    }

    private func promptSplitColumn(_ column: Int) {
        guard let inspector = inspectorDocument, let window = view.window,
              column >= 0, column < inspector.columnNames.count else { return }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Split “%@”"), inspector.columnNames[column])
        alert.informativeText = String(localized: "Split each value into new columns at every match.")
        alert.addButton(withTitle: String(localized: "Split"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Separator or pattern")
        field.usesSingleLineMode = true
        let mode = NSSegmentedControl(
            labels: [String(localized: "Delimiter"), String(localized: "Regex")],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        mode.selectedSegment = 0
        let stack = accessoryStack(with: [field, mode])
        alert.accessoryView = stack

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applySplit(column: column, separator: field.stringValue, isRegex: mode.selectedSegment == 1)
        }
        DispatchQueue.main.async { alert.window.makeFirstResponder(field) }
    }

    private func promptMergeColumns(_ column: Int) {
        guard let inspector = inspectorDocument, let window = view.window,
              column + 1 < inspector.columnNames.count else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "Merge “%@” with “%@”"),
            inspector.columnNames[column],
            inspector.columnNames[column + 1]
        )
        alert.informativeText = String(localized: "Join the two columns into one, placing this text between the values.")
        alert.addButton(withTitle: String(localized: "Merge"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Separator (optional)")
        field.usesSingleLineMode = true
        alert.accessoryView = accessoryStack(with: [field])

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let inspector = self.inspectorDocument else { return }
            let removedName = column + 1 < inspector.columnNames.count ? inspector.columnNames[column + 1] : nil
            inspector.mergeColumns(at: column, separator: field.stringValue)
            if let removedName { self.removeLayoutKey(removedName) }
        }
        DispatchQueue.main.async { alert.window.makeFirstResponder(field) }
    }

    private func applySplit(column: Int, separator: String, isRegex: Bool) {
        guard !separator.isEmpty else { return }
        if isRegex, (try? NSRegularExpression(pattern: separator)) == nil {
            presentInvalidPattern()
            return
        }
        guard let inspector = inspectorDocument else { return }
        let oldName = column < inspector.columnNames.count ? inspector.columnNames[column] : nil
        let oldCount = inspector.columnNames.count
        inspector.splitColumn(at: column, separator: separator, isRegex: isRegex)
        guard let oldName else { return }
        let pieceCount = inspector.columnNames.count - oldCount + 1
        let upper = min(column + max(pieceCount, 0), inspector.columnNames.count)
        let newNames = column < upper ? Array(inspector.columnNames[column..<upper]) : []
        replaceLayoutKey(oldName, with: newNames)
    }

    private func presentInvalidPattern() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Invalid pattern")
        alert.informativeText = String(localized: "That regular expression could not be read. Check the syntax and try again.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }

    private func accessoryStack(with views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(views.count) * 32)
        return stack
    }

    @objc func inspectorSetColumnType(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let assignment = menuItem.representedObject as? ColumnTypeAssignment else { return }
        inspectorDocument?.setTypeOverride(assignment.type, forColumn: assignment.column)
    }

    fileprivate func columnStructureMenuItems(forColumn index: Int) -> [NSMenuItem] {
        guard let inspector = inspectorDocument, index >= 0, index < inspector.columnNames.count else { return [] }
        return InspectorColumnMenuBuilder.structureItems(
            forColumn: index,
            currentType: inspector.displayedType(forColumn: index),
            deleteColumns: columnDeleteSelection(clicked: index),
            canMerge: index + 1 < inspector.columnNames.count
        )
    }

    private func columnDeleteSelection(clicked: Int) -> [Int] {
        InspectorColumnTargets.deleteMenuSelection(clicked: clicked, fullySelected: selectedFullColumns())
    }

    fileprivate func rowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem] {
        guard inspectorDocument != nil else { return [] }
        return InspectorRowMenuBuilder.structureItems(forRow: displayRow)
    }

    private func renameLayoutKey(from oldName: String, to newName: String) {
        if state.columnLayout.columnOrder != nil {
            state.columnLayout.columnOrder = state.columnLayout.columnOrder?.map { $0 == oldName ? newName : $0 }
        }
        if let width = state.columnLayout.columnWidths.removeValue(forKey: oldName) {
            state.columnLayout.columnWidths[newName] = width
        }
        if state.columnLayout.hiddenColumns.remove(oldName) != nil {
            state.columnLayout.hiddenColumns.insert(newName)
        }
    }

    private func removeLayoutKey(_ name: String) {
        if state.columnLayout.columnOrder != nil {
            state.columnLayout.columnOrder = state.columnLayout.columnOrder?.filter { $0 != name }
        }
        state.columnLayout.columnWidths.removeValue(forKey: name)
        state.columnLayout.hiddenColumns.remove(name)
    }

    private func insertLayoutKey(_ name: String, relativeTo anchor: String, after: Bool) {
        guard var order = state.columnLayout.columnOrder,
              let anchorPos = order.firstIndex(of: anchor) else { return }
        order.insert(name, at: after ? anchorPos + 1 : anchorPos)
        state.columnLayout.columnOrder = order
    }

    private func replaceLayoutKey(_ oldName: String, with newNames: [String]) {
        if var order = state.columnLayout.columnOrder, let position = order.firstIndex(of: oldName) {
            order.replaceSubrange(position...position, with: newNames)
            state.columnLayout.columnOrder = order
        }
        state.columnLayout.columnWidths.removeValue(forKey: oldName)
        state.columnLayout.hiddenColumns.remove(oldName)
    }

    private func promptForColumnName(
        title: String,
        initial: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let window = view.window else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: "Column name")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = initial
        textField.usesSingleLineMode = true
        alert.accessoryView = textField
        alert.beginSheetModal(for: window) { response in
            let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(response == .alertFirstButtonReturn ? trimmed : nil)
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(textField)
        }
    }

    @objc func toggleInspectorFilter(_ sender: Any?) {
        let wasActive = isFilterActive
        state.isFilterVisible.toggle()
        if state.isFilterVisible, state.filters.isEmpty {
            state.filters = [FilterClause.empty()]
        }
        if wasActive != isFilterActive {
            recomputeDisplay()
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            return nsDocument?.undoManager?.canUndo ?? false
        case #selector(redo(_:)):
            return nsDocument?.undoManager?.canRedo ?? false
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)),
             #selector(toggleInspectorFilter(_:)), #selector(inspectorAddRow(_:)),
             #selector(inspectorInsertRowAbove(_:)), #selector(inspectorInsertRowBelow(_:)),
             #selector(inspectorInsertColumnLeft(_:)), #selector(inspectorInsertColumnRight(_:)),
             #selector(inspectorSplitColumn(_:)), #selector(inspectorMergeColumns(_:)),
             #selector(inspectorToggleHeaderRow(_:)):
            return nsDocument != nil
        case #selector(inspectorDeleteColumn(_:)):
            guard nsDocument != nil else { return false }
            if let menuItem = item as? NSMenuItem, menuItem.representedObject is [Int] { return true }
            return !selectedFullColumns().isEmpty
        case #selector(inspectorDeleteSelectedRows(_:)):
            return !state.selectedRowIndices.isEmpty
        default:
            return true
        }
    }

    // MARK: - Display computation

    private var isFilterActive: Bool {
        state.isFilterVisible && !activeFilters.isEmpty
    }

    private var activeFilters: [FilterClause] {
        let columnCount = state.columnNames.count
        return state.filters.filter { clause in
            guard clause.column >= 0, clause.column < columnCount else { return false }
            return clause.op.needsValue ? !clause.value.isEmpty : true
        }
    }

    private func scheduleFilterRecompute() {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.recomputeDisplay()
        }
    }

    private func recomputeDisplay() {
        recomputeTask?.cancel()
        guard let inspectorDocument else {
            state.isComputing = false
            displayIndices = nil
            applyViewIdentity(filter: [], sort: [])
            refreshVisiblePage()
            return
        }
        let columnCount = inspectorDocument.columnNames.count
        let filters = activeFilters
        let sortSpecs: [SortSpec] = state.sortState.columns.compactMap { column -> SortSpec? in
            guard column.columnIndex >= 0, column.columnIndex < columnCount else { return nil }
            return SortSpec(
                column: column.columnIndex,
                ascending: column.direction == .ascending,
                numeric: Self.isNumeric(inspectorDocument.displayedType(forColumn: column.columnIndex))
            )
        }
        let filterActive = !filters.isEmpty
        let sortActive = !sortSpecs.isEmpty

        guard filterActive || sortActive else {
            state.isComputing = false
            displayIndices = nil
            applyViewIdentity(filter: filters, sort: sortSpecs)
            refreshVisiblePage()
            return
        }

        applyViewIdentity(filter: filters, sort: sortSpecs)
        let snapshot = inspectorDocument.snapshot()
        state.isComputing = true

        recomputeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let indices = Self.computeDisplayIndices(
                snapshot: snapshot,
                filters: filters,
                sorts: sortSpecs
            )
            if Task.isCancelled { return }
            await MainActor.run {
                guard !Task.isCancelled, let self else { return }
                self.state.isComputing = false
                self.displayIndices = indices
                self.refreshVisiblePage()
            }
        }
    }

    nonisolated private static func computeDisplayIndices(
        snapshot: any InspectorDataSnapshot,
        filters: [FilterClause],
        sorts: [SortSpec]
    ) -> [Int] {
        let total = snapshot.rowCount
        var indices: [Int]
        if !filters.isEmpty {
            indices = []
            indices.reserveCapacity(total)
            var index = 0
            while index < total {
                if index & 0x1FFF == 0, Task.isCancelled { return [] }
                var allMatch = true
                for clause in filters {
                    let cell = snapshot.field(at: index, column: clause.column)
                    if !clause.op.matches(cell, value: clause.value) {
                        allMatch = false
                        break
                    }
                }
                if allMatch {
                    indices.append(index)
                }
                index += 1
            }
        } else {
            indices = Array(0..<total)
        }

        guard !Task.isCancelled else { return [] }
        guard !sorts.isEmpty else { return indices }

        var keyed: [(index: Int, keys: [SortKey])] = []
        keyed.reserveCapacity(indices.count)
        for (offset, index) in indices.enumerated() {
            if offset & 0x1FFF == 0, Task.isCancelled { return [] }
            var keys: [SortKey] = []
            keys.reserveCapacity(sorts.count)
            for spec in sorts {
                let raw = snapshot.field(at: index, column: spec.column)
                if spec.numeric {
                    keys.append(.double(Double(raw) ?? -.greatestFiniteMagnitude))
                } else {
                    keys.append(.text(naturalSortKey(raw)))
                }
            }
            keyed.append((index, keys))
        }

        keyed.sort { lhs, rhs in
            for (i, spec) in sorts.enumerated() {
                let result = compareKeys(lhs.keys[i], rhs.keys[i])
                if result == .orderedSame { continue }
                return spec.ascending ? result == .orderedAscending : result == .orderedDescending
            }
            return false
        }
        guard !Task.isCancelled else { return [] }
        return keyed.map(\.index)
    }

    nonisolated private static func compareKeys(_ lhs: SortKey, _ rhs: SortKey) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.double(a), .double(b)):
            return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        case let (.text(a), .text(b)):
            return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        default:
            return .orderedSame
        }
    }


    private func refreshVisiblePage() {
        guard let inspectorDocument else { return }
        let columnNames = inspectorDocument.columnNames
        let columnCount = columnNames.count
        let visibleTotal = displayIndices?.count ?? inspectorDocument.rowCount
        let pageSize = max(state.pageSize, 1)

        if case .focusStoreIndex(let target) = pendingPostRefresh,
           let displayRow = locateDisplayRow(forStoreIndex: target) {
            let desiredPage = (displayRow / pageSize) * pageSize
            if state.pageOffset != desiredPage {
                state.pageOffset = desiredPage
            }
        }

        let maxOffset = visibleTotal == 0 ? 0 : ((visibleTotal - 1) / pageSize) * pageSize
        state.pageOffset = min(max(state.pageOffset, 0), maxOffset)
        let start = state.pageOffset
        let end = min(start + pageSize, visibleTotal)

        var storeIndices: [Int] = []
        var rows = ContiguousArray<Row>()
        storeIndices.reserveCapacity(end - start)
        rows.reserveCapacity(end - start)

        if let displayIndices {
            for displayRow in start..<end {
                let logicalIndex = displayIndices[displayRow]
                storeIndices.append(logicalIndex)
                let values = (0..<columnCount).map {
                    PluginCellValue.text(inspectorDocument.value(row: logicalIndex, column: $0))
                }
                rows.append(Row(id: .existing(logicalIndex), values: ContiguousArray(values)))
            }
        } else {
            let pageCells = inspectorDocument.pageRows(offset: start, limit: end - start)
            for (rowOffset, cells) in pageCells.enumerated() {
                let logicalIndex = start + rowOffset
                storeIndices.append(logicalIndex)
                let values = cells.map { PluginCellValue.text($0) }
                rows.append(Row(id: .existing(logicalIndex), values: ContiguousArray(values)))
            }
        }

        displayToStore = storeIndices
        let columnTypes = (0..<columnCount).map {
            Self.columnType(for: inspectorDocument.displayedType(forColumn: $0))
        }
        state.tableRows = TableRows(rows: rows, columns: columnNames, columnTypes: columnTypes)
        state.columnNames = columnNames
        state.totalRowCount = inspectorDocument.rowCount
        state.visibleRowCount = visibleTotal
        state.pageCount = visibleTotal == 0 ? 1 : (visibleTotal + pageSize - 1) / pageSize
        inspectorChangeManager.bumpReload()
        scheduleGridReload()
        applyPendingPostRefresh()
    }

    private func applyPendingPostRefresh() {
        let action = pendingPostRefresh
        pendingPostRefresh = nil
        let targetIndex: Int?
        switch action {
        case nil:
            return
        case .selectClamped(let displayRow):
            let visibleCount = state.tableRows.rows.count
            if visibleCount == 0 {
                targetIndex = nil
            } else {
                targetIndex = min(max(displayRow, 0), visibleCount - 1)
            }
        case .focusStoreIndex(let target):
            guard let displayRow = locateDisplayRow(forStoreIndex: target) else {
                return
            }
            let withinPage = displayRow - state.pageOffset
            targetIndex = (withinPage >= 0 && withinPage < state.tableRows.rows.count) ? withinPage : nil
        }
        guard let targetIndex else {
            state.selectedRowIndices = []
            return
        }
        state.selectedRowIndices = [targetIndex]
        DispatchQueue.main.async { [weak self] in
            guard let coordinator = self?.gridDelegate.coordinator,
                  let tableView = coordinator.tableView else { return }
            coordinator.isApplyingProgrammaticRowSelection = true
            tableView.selectRowIndexes(IndexSet(integer: targetIndex), byExtendingSelection: false)
            coordinator.isApplyingProgrammaticRowSelection = false
            tableView.scrollRowToVisible(targetIndex)
            tableView.window?.makeFirstResponder(tableView)
        }
    }

    private func locateDisplayRow(forStoreIndex storeIndex: Int) -> Int? {
        if let displayIndices {
            return displayIndices.firstIndex(of: storeIndex)
        }
        let total = inspectorDocument?.rowCount ?? 0
        guard storeIndex >= 0, storeIndex < total else { return nil }
        return storeIndex
    }

    private func scheduleGridReload() {
        guard !gridReloadScheduled else { return }
        gridReloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gridReloadScheduled = false
            self.gridDelegate.coordinator?.applyDelta(.fullReplace)
        }
    }

    private static func isNumeric(_ type: InspectorColumnType) -> Bool {
        type == .integer || type == .real
    }

    private static func columnType(for inferred: InspectorColumnType) -> ColumnType {
        switch inferred {
        case .integer: return .integer(rawType: "INTEGER")
        case .real:    return .decimal(rawType: "REAL")
        case .boolean: return .boolean(rawType: "BOOLEAN")
        case .date:    return .date(rawType: "DATE")
        case .text:    return .text(rawType: "TEXT")
        }
    }
}

private struct SortSpec: Sendable, Equatable {
    let column: Int
    let ascending: Bool
    let numeric: Bool
}

private enum SortKey: Sendable {
    case double(Double)
    case text(String)
}

@MainActor
@Observable
final class InspectorViewState {
    var tableRows = TableRows()
    var selectedRowIndices: Set<Int> = []
    var sortState = SortState()
    var columnLayout = ColumnLayoutState()
    var columnNames: [String] = []
    var totalRowCount: Int = 0
    var visibleRowCount: Int = 0
    var pageOffset: Int = 0
    var pageSize: Int = 1_000
    var pageCount: Int = 1
    var isComputing: Bool = false
    var isFilterVisible: Bool = false
    var filters: [FilterClause] = []
}

@MainActor
private final class InspectorGridDelegate: DataGridViewDelegate {
    weak var owner: InspectorViewController?
    weak var coordinator: TableViewCoordinator?

    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        coordinator = tableViewCoordinator
    }

    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {
        owner?.handleCellEdit(displayRow: row, column: column, newValue: newValue)
    }

    func dataGridDeleteRows(_ indices: Set<Int>) {
        owner?.handleDeleteRows(indices)
    }

    func dataGridAddRow() {
        owner?.handleAddRow()
    }

    func dataGridCopyRows(_ indices: Set<Int>) {
        owner?.handleCopyRows(indices)
    }

    func dataGridPasteRows() {
        owner?.handlePasteRows()
    }

    func dataGridSortStateChanged(_ state: SortState) {
        owner?.handleSortChanged(state)
    }

    func dataGridColumnStructureMenuItems(forColumn dataColumnIndex: Int) -> [NSMenuItem] {
        owner?.columnStructureMenuItems(forColumn: dataColumnIndex) ?? []
    }

    func dataGridRowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem] {
        owner?.rowStructureMenuItems(forRow: displayRow) ?? []
    }

    func dataGridUndo() {
        owner?.handleUndo()
    }

    func dataGridRedo() {
        owner?.handleRedo()
    }
}

private struct InspectorRootView: View {
    @Bindable var state: InspectorViewState
    let changeManager: AnyChangeManager
    let delegate: any DataGridViewDelegate
    let onFilterChanged: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.isFilterVisible {
                InspectorFilterBar(state: state, onChange: onFilterChanged)
                Divider()
            }
            ZStack {
                DataGridView(
                    tableRowsProvider: { state.tableRows },
                    tableRowsMutator: { mutate in mutate(&state.tableRows) },
                    paginationOffsetProvider: { state.pageOffset },
                    changeManager: changeManager,
                    isEditable: true,
                    configuration: configuration,
                    delegate: delegate,
                    selectedRowIndices: $state.selectedRowIndices,
                    sortState: $state.sortState,
                    columnLayout: $state.columnLayout
                )
                if state.tableRows.rows.isEmpty, !state.isComputing {
                    emptyStateView
                }
            }
            Divider()
            InspectorStatusBar(
                state: state,
                onPreviousPage: onPreviousPage,
                onNextPage: onNextPage
            )
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            state.totalRowCount == 0
                ? String(localized: "No rows")
                : String(localized: "No matching rows"),
            systemImage: state.totalRowCount == 0 ? "doc" : "line.3.horizontal.decrease.circle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var configuration: DataGridConfiguration {
        var config = DataGridConfiguration()
        config.showRowNumbers = true
        return config
    }
}
