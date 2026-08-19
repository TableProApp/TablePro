//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit

struct HeaderSortTransition: Equatable {
    let newState: SortState
}

enum HeaderSortCycle {
    static func nextTransition(
        state: SortState,
        clickedColumn: Int,
        isMultiSort: Bool
    ) -> HeaderSortTransition {
        if isMultiSort {
            return multiSortTransition(state: state, clickedColumn: clickedColumn)
        }
        return singleSortTransition(state: state, clickedColumn: clickedColumn)
    }

    private static func multiSortTransition(state: SortState, clickedColumn: Int) -> HeaderSortTransition {
        guard let existingIndex = state.columns.firstIndex(where: { $0.columnIndex == clickedColumn }) else {
            var newState = state
            newState.columns.append(SortColumn(columnIndex: clickedColumn, direction: .ascending))
            return HeaderSortTransition(newState: newState)
        }

        let existing = state.columns[existingIndex]
        switch existing.direction {
        case .ascending:
            var newState = state
            newState.columns[existingIndex].direction = .descending
            return HeaderSortTransition(newState: newState)
        case .descending:
            var newState = state
            newState.columns.remove(at: existingIndex)
            return HeaderSortTransition(newState: newState)
        }
    }

    private static func singleSortTransition(state: SortState, clickedColumn: Int) -> HeaderSortTransition {
        guard let primary = state.columns.first, primary.columnIndex == clickedColumn else {
            var newState = SortState()
            newState.columns = [SortColumn(columnIndex: clickedColumn, direction: .ascending)]
            return HeaderSortTransition(newState: newState)
        }

        switch primary.direction {
        case .ascending:
            var newState = SortState()
            newState.columns = [SortColumn(columnIndex: clickedColumn, direction: .descending)]
            return HeaderSortTransition(newState: newState)
        case .descending:
            return HeaderSortTransition(newState: SortState())
        }
    }
}

@MainActor
final class SortableHeaderView: NSTableHeaderView {
    weak var coordinator: TableViewCoordinator?

    private static let clickDragThreshold: CGFloat = 4
    private static let resizeZoneWidth: CGFloat = 4
    private static let fallbackHeight: CGFloat = 28

    private var pendingClickStartLocation: NSPoint?
    private var dragOccurredDuringClick = false
    private var mouseMovedTrackingArea: NSTrackingArea?
    private var hoveredColumnIndex: Int?

    private let naturalHeight: CGFloat
    private var commentsByColumn: [NSUserInterfaceItemIdentifier: String] = [:]

    var commentHeaderHeight: CGFloat {
        naturalHeight + SortableHeaderCell.commentLineHeight
    }

    var showsComments = false {
        didSet {
            guard showsComments != oldValue else { return }
            applyHeaderHeight()
        }
    }

    func updateComments(_ comments: [NSUserInterfaceItemIdentifier: String]) {
        guard commentsByColumn != comments else { return }
        commentsByColumn = comments
        needsDisplay = true
    }

    func comment(for cell: NSCell) -> String? {
        guard let tableView,
              let column = tableView.tableColumns.first(where: { $0.headerCell === cell }) else {
            return nil
        }
        return commentsByColumn[column.identifier]
    }

    private var emphasisObservers: [NSObjectProtocol] = []
    private var firstResponderObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        naturalHeight = frameRect.height > 0 ? frameRect.height : Self.fallbackHeight
        super.init(frame: frameRect)
    }

    deinit {
        emphasisObservers.forEach(NotificationCenter.default.removeObserver)
    }

    required init?(coder: NSCoder) {
        naturalHeight = Self.fallbackHeight
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        emphasisObservers.forEach(NotificationCenter.default.removeObserver)
        emphasisObservers.removeAll()
        firstResponderObservation = nil
        guard let window else {
            applyEmphasis(false)
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEmphasis() }
            }
            emphasisObservers.append(observer)
        }
        /// The header and the row bodies are two halves of one selection, so they have to agree on
        /// what emphasis means. `NSTableRowView.isEmphasized` is key window *and* table focus, and
        /// keying the header on the window alone left a sorted column accent blue over a grey body.
        /// AppKit publishes no first-responder notification but does notify KVO by hand.
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshEmphasis() }
        }
    }

    private func refreshEmphasis() {
        applyEmphasis(
            SortableHeaderEmphasis.isEmphasized(
                tableViewHoldsFocus: SortableHeaderEmphasis.holdsFocus(tableView: tableView, in: window),
                isKeyWindow: window?.isKeyWindow ?? false
            )
        )
    }

    private func applyEmphasis(_ isEmphasized: Bool) {
        guard let tableView else { return }
        var changed = false
        for column in tableView.tableColumns {
            guard let cell = column.headerCell as? SortableHeaderCell,
                  cell.isEmphasized != isEmphasized else { continue }
            cell.isEmphasized = isEmphasized
            changed = true
        }
        guard changed else { return }
        needsDisplay = true
    }

    private func applyHeaderHeight() {
        let targetHeight = showsComments ? commentHeaderHeight : naturalHeight
        if frame.height != targetHeight {
            setFrameSize(NSSize(width: frame.width, height: targetHeight))
        }
        tableView?.enclosingScrollView?.tile()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SortableHeaderChrome.fillBackground(dirtyRect)
        super.draw(dirtyRect)
        SortableHeaderChrome.drawBottomSeparator(in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseMovedTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseMovedTrackingArea = area
    }

    /// `NSCursor.resizeLeftRight` is deprecated in favour of the direction-aware column
    /// cursor, which the rest of the app already uses.
    static var columnResizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    override func mouseMoved(with event: NSEvent) {
        guard tableView != nil else {
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if isInResizeZone(point: point) {
            SortableHeaderView.columnResizeCursor.set()
            updateFunnelHover(column: nil)
        } else {
            NSCursor.arrow.set()
            updateFunnelHover(column: hoverableColumn(at: point))
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateFunnelHover(column: nil)
    }

    private func isInResizeZone(point: NSPoint) -> Bool {
        guard let tableView else { return false }
        let zone = Self.resizeZoneWidth
        return tableView.tableColumns.enumerated().contains { index, column in
            guard column.resizingMask.contains(.userResizingMask) else { return false }
            let edge = headerRect(ofColumn: index).maxX
            return abs(point.x - edge) <= zone
        }
    }

    private func hoverableColumn(at point: NSPoint) -> Int? {
        guard let tableView else { return nil }
        let columnIndex = column(at: point)
        guard columnIndex >= 0, columnIndex < tableView.numberOfColumns else { return nil }
        guard tableView.tableColumns[columnIndex].identifier != ColumnIdentitySchema.rowNumberIdentifier else { return nil }
        return columnIndex
    }

    private func updateFunnelHover(column columnIndex: Int?) {
        guard hoveredColumnIndex != columnIndex else { return }
        let previous = hoveredColumnIndex
        hoveredColumnIndex = columnIndex
        guard let tableView else { return }
        for index in [previous, columnIndex].compactMap({ $0 }) {
            guard index >= 0, index < tableView.tableColumns.count,
                  let cell = tableView.tableColumns[index].headerCell as? SortableHeaderCell else { continue }
            let shouldShow = index == columnIndex
            if cell.isFunnelVisible != shouldShow {
                cell.isFunnelVisible = shouldShow
                setNeedsDisplay(headerRect(ofColumn: index))
            }
        }
    }

    func updateValueFilterIndicators(activeColumns: Set<Int>) {
        guard let tableView, let coordinator else { return }
        for (columnIndex, column) in tableView.tableColumns.enumerated() {
            guard let cell = column.headerCell as? SortableHeaderCell,
                  let dataIndex = coordinator.dataColumnIndex(from: column.identifier) else { continue }
            let shouldBeFiltered = activeColumns.contains(dataIndex)
            if cell.isValueFiltered != shouldBeFiltered {
                cell.isValueFiltered = shouldBeFiltered
                setNeedsDisplay(headerRect(ofColumn: columnIndex))
            }
        }
    }

    func updateColumnSelectionIndicators(selectedColumns: IndexSet, dirtyColumns: IndexSet) {
        guard let tableView = tableView, let coordinator = coordinator else { return }
        for (columnIndex, column) in tableView.tableColumns.enumerated() {
            guard let cell = column.headerCell as? SortableHeaderCell,
                  let dataIndex = coordinator.dataColumnIndex(from: column.identifier) else { continue }
            let shouldBeSelected = selectedColumns.contains(dataIndex)
            if cell.isColumnSelected != shouldBeSelected {
                cell.isColumnSelected = shouldBeSelected
                setNeedsDisplay(headerRect(ofColumn: columnIndex))
            } else if dirtyColumns.contains(dataIndex) {
                setNeedsDisplay(headerRect(ofColumn: columnIndex))
            }
        }
    }

    func applySortState(_ state: SortState, schema: ColumnIdentitySchema) {
        guard let tableView else { return }
        applySortDescriptors(state: state, schema: schema, in: tableView)
        applySortIndicators(state: state, schema: schema, in: tableView)
    }

    private func applySortDescriptors(
        state: SortState,
        schema: ColumnIdentitySchema,
        in tableView: NSTableView
    ) {
        var primary: NSSortDescriptor?
        if let leading = state.columns.first, let name = schema.columnName(for: leading.columnIndex) {
            primary = NSSortDescriptor(key: name, ascending: leading.direction == .ascending)
        }
        let current = tableView.sortDescriptors.first
        guard current?.key != primary?.key || current?.ascending != primary?.ascending else { return }
        tableView.sortDescriptors = primary.map { [$0] } ?? []
    }

    private func applySortIndicators(
        state: SortState,
        schema: ColumnIdentitySchema,
        in tableView: NSTableView
    ) {
        var priorityByIdentifier: [NSUserInterfaceItemIdentifier: (direction: SortDirection, priority: Int)] = [:]
        for (index, sortCol) in state.columns.enumerated() {
            guard let identifier = schema.identifier(for: sortCol.columnIndex) else { continue }
            priorityByIdentifier[identifier] = (sortCol.direction, index + 1)
        }

        for (columnIndex, column) in tableView.tableColumns.enumerated() {
            guard let cell = column.headerCell as? SortableHeaderCell else { continue }
            let entry = priorityByIdentifier[column.identifier]
            let newDirection = entry?.direction
            let newPriority = entry?.priority
            if cell.sortDirection != newDirection || cell.sortPriority != newPriority {
                cell.sortDirection = newDirection
                cell.sortPriority = newPriority
                setNeedsDisplay(headerRect(ofColumn: columnIndex))
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = pendingClickStartLocation {
            let current = convert(event.locationInWindow, from: nil)
            if abs(current.x - start.x) > Self.clickDragThreshold ||
                abs(current.y - start.y) > Self.clickDragThreshold {
                dragOccurredDuringClick = true
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tableView = tableView,
              let coordinator = coordinator else {
            super.mouseDown(with: event)
            return
        }

        let pointInHeader = convert(event.locationInWindow, from: nil)
        if isInResizeZone(point: pointInHeader) {
            super.mouseDown(with: event)
            return
        }

        let columnIndex = column(at: pointInHeader)
        guard columnIndex >= 0, columnIndex < tableView.numberOfColumns else {
            super.mouseDown(with: event)
            return
        }

        let column = tableView.tableColumns[columnIndex]
        guard column.identifier != ColumnIdentitySchema.rowNumberIdentifier,
              let dataIndex = coordinator.dataColumnIndex(from: column.identifier) else {
            super.mouseDown(with: event)
            return
        }

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags.isEmpty,
           let cell = column.headerCell as? SortableHeaderCell {
            let funnelRect = cell.funnelRect(forBounds: headerRect(ofColumn: columnIndex))
            if funnelRect.insetBy(dx: -2, dy: -4).contains(pointInHeader) {
                coordinator.presentValueFilterPopover(forColumn: dataIndex, anchor: funnelRect, in: self)
                return
            }
        }

        let originalColumnOrder = tableView.tableColumns.map { $0.identifier }
        let originalColumnWidths = tableView.tableColumns.map { $0.width }
        pendingClickStartLocation = pointInHeader
        dragOccurredDuringClick = false
        defer {
            pendingClickStartLocation = nil
            dragOccurredDuringClick = false
        }

        super.mouseDown(with: event)

        let columnOrderChanged = tableView.tableColumns.map { $0.identifier } != originalColumnOrder
        let columnWidthsChanged = tableView.tableColumns.map { $0.width } != originalColumnWidths
        if dragOccurredDuringClick || columnOrderChanged || columnWidthsChanged {
            return
        }

        if modifierFlags.contains(.command) && !modifierFlags.contains(.shift) {
            coordinator.extendColumnSelection(dataIndex)
            return
        }

        let isMultiSort = modifierFlags.contains(.shift)
        let transition = HeaderSortCycle.nextTransition(
            state: coordinator.currentSortState,
            clickedColumn: dataIndex,
            isMultiSort: isMultiSort
        )

        let schema = coordinator.identitySchema
        let newState = SortColumnResolver.stamped(transition.newState, displayColumns: schema.columnNames)

        coordinator.currentSortState = newState
        applySortState(newState, schema: schema)
        coordinator.delegate?.dataGridSortStateChanged(newState)
    }
}
