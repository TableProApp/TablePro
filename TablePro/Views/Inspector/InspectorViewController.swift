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
        state.pageSize = max(1, AppSettingsManager.shared.dataGrid.defaultPageSize)
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
        undoManager?.setActionName(String(localized: "Paste"))
        for row in rows {
            let newRowIndex = inspectorDocument.rowCount
            inspectorDocument.appendRow()
            for (column, value) in row.enumerated() {
                inspectorDocument.setCell(row: newRowIndex, column: column, to: value)
            }
        }
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
        pendingPostRefresh = .selectClamped(displayRow: sortedDisplay.first ?? 0)
        inspectorDocument.removeRows(at: IndexSet(storeIndices))
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

    @objc func inspectorInsertColumnBefore(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let inspector = inspectorDocument,
              menuItem.tag >= 0, menuItem.tag < inspector.columnNames.count else { return }
        let anchorIndex = menuItem.tag
        let anchorName = inspector.columnNames[anchorIndex]
        promptForColumnName(title: String(localized: "Insert Column"), initial: "") { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.inspectorDocument?.insertColumn(at: anchorIndex, name: name)
            self.insertLayoutKey(name, relativeTo: anchorName, after: false)
        }
    }

    @objc func inspectorInsertColumnAfter(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let inspector = inspectorDocument,
              menuItem.tag >= 0, menuItem.tag < inspector.columnNames.count else { return }
        let anchorIndex = menuItem.tag
        let anchorName = inspector.columnNames[anchorIndex]
        promptForColumnName(title: String(localized: "Insert Column"), initial: "") { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.inspectorDocument?.insertColumn(at: anchorIndex + 1, name: name)
            self.insertLayoutKey(name, relativeTo: anchorName, after: true)
        }
    }

    @objc func inspectorDeleteColumn(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let inspector = inspectorDocument,
              menuItem.tag >= 0, menuItem.tag < inspector.columnNames.count else { return }
        let name = inspector.columnNames[menuItem.tag]
        inspector.removeColumn(at: menuItem.tag)
        removeLayoutKey(name)
    }

    @objc func inspectorSetColumnType(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let assignment = menuItem.representedObject as? ColumnTypeAssignment else { return }
        inspectorDocument?.setTypeOverride(assignment.type, forColumn: assignment.column)
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
             #selector(toggleInspectorFilter(_:)), #selector(inspectorAddRow(_:)):
            return nsDocument != nil
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
