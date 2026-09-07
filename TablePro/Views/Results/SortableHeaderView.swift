//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit
import os

struct HeaderSortTransition: Equatable {
    let newState: SortState
}

/// The header click cycle: first direction, its opposite, then the engine's own order.
///
/// Every transition it returns is stamped `.user`, including the empty one. The empty state is the
/// user saying "no order", which is a different thing from a tab that has not decided yet, and only
/// the stamp keeps `wantsDefaultSort` from writing the app default back over it.
enum HeaderSortCycle {
    static func nextTransition(
        state: SortState,
        clickedColumn: Int,
        isMultiSort: Bool,
        firstClickDirection: SortDirection
    ) -> HeaderSortTransition {
        let transition = isMultiSort
            ? multiSortTransition(state: state, clickedColumn: clickedColumn, firstClickDirection: firstClickDirection)
            : singleSortTransition(state: state, clickedColumn: clickedColumn, firstClickDirection: firstClickDirection)
        var stamped = transition.newState
        stamped.source = .user
        return HeaderSortTransition(newState: stamped)
    }

    private static func multiSortTransition(
        state: SortState,
        clickedColumn: Int,
        firstClickDirection: SortDirection
    ) -> HeaderSortTransition {
        guard let existingIndex = state.columns.firstIndex(where: { $0.columnIndex == clickedColumn }) else {
            var newState = state
            newState.columns.append(SortColumn(columnIndex: clickedColumn, direction: firstClickDirection))
            return HeaderSortTransition(newState: newState)
        }

        let existing = state.columns[existingIndex]
        if existing.direction == firstClickDirection {
            var newState = state
            newState.columns[existingIndex].direction = firstClickDirection.opposite
            return HeaderSortTransition(newState: newState)
        }
        var newState = state
        newState.columns.remove(at: existingIndex)
        return HeaderSortTransition(newState: newState)
    }

    private static func singleSortTransition(
        state: SortState,
        clickedColumn: Int,
        firstClickDirection: SortDirection
    ) -> HeaderSortTransition {
        guard let primary = state.columns.first, primary.columnIndex == clickedColumn else {
            var newState = SortState()
            newState.columns = [SortColumn(columnIndex: clickedColumn, direction: firstClickDirection)]
            return HeaderSortTransition(newState: newState)
        }

        if primary.direction == firstClickDirection {
            var newState = SortState()
            newState.columns = [SortColumn(columnIndex: clickedColumn, direction: firstClickDirection.opposite)]
            return HeaderSortTransition(newState: newState)
        }
        return HeaderSortTransition(newState: SortState())
    }
}

@MainActor
final class SortableHeaderView: NSTableHeaderView {
    weak var coordinator: TableViewCoordinator?

    private static let clickDragThreshold: CGFloat = 4
    private static let resizeZoneWidth: CGFloat = 4
    private static let fallbackHeight: CGFloat = 28

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

    private let emphasisObservers = OSAllocatedUnfairLock<[any NSObjectProtocol]>(uncheckedState: [])
    private var firstResponderObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        naturalHeight = frameRect.height > 0 ? frameRect.height : Self.fallbackHeight
        super.init(frame: frameRect)
    }

    deinit {
        emphasisObservers.withLockUnchecked { $0.forEach(NotificationCenter.default.removeObserver) }
    }

    required init?(coder: NSCoder) {
        naturalHeight = Self.fallbackHeight
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        emphasisObservers.withLockUnchecked {
            $0.forEach(NotificationCenter.default.removeObserver)
            $0.removeAll()
        }
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
            emphasisObservers.withLockUnchecked { $0.append(observer) }
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

    /// `headerRect(ofColumn:)` gives a hidden column a zero rect, so its trailing edge is x = 0. The
    /// pool keeps user-hidden columns and the surplus slots of a wider result attached with
    /// `userResizingMask` set, and each one reports a divider at the header's leading edge.
    internal func isInResizeZone(point: NSPoint) -> Bool {
        guard let tableView, let coordinator else { return false }
        let zone = Self.resizeZoneWidth
        return tableView.tableColumns.enumerated().contains { index, column in
            guard column.resizingMask.contains(.userResizingMask),
                  coordinator.presentsColumn(column) else { return false }
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

    /// Mirrors the whole sort onto `tableView.sortDescriptors`, never just its leading entry.
    ///
    /// AppKit maintains this array itself on every unmodified header click, and a plain click on a
    /// second column *prepends* the new descriptor while keeping the old ones behind it. Comparing
    /// only `.first` therefore left AppKit's stale secondary in place, so the array claimed a
    /// two-column sort the app was not running.
    private func applySortDescriptors(
        state: SortState,
        schema: ColumnIdentitySchema,
        in tableView: NSTableView
    ) {
        let descriptors = Self.presentedColumns(of: state, in: schema).map { entry in
            NSSortDescriptor(key: entry.name, ascending: entry.direction == .ascending)
        }
        let current = tableView.sortDescriptors
        guard current.count != descriptors.count
            || zip(current, descriptors).contains(where: { $0.key != $1.key || $0.ascending != $1.ascending })
        else { return }
        tableView.sortDescriptors = descriptors
    }

    /// The sorted-column chrome, and the only place the grid tells an assistive client what is sorted.
    ///
    /// `tableView.sortDescriptors` reaches no accessibility client (measured: the header cell's
    /// direction stays `.unknown` through every change to it). `setAccessibilitySortDirection` is the
    /// attribute VoiceOver actually reads, so it is set here per column and cleared on the rest.
    private func applySortIndicators(
        state: SortState,
        schema: ColumnIdentitySchema,
        in tableView: NSTableView
    ) {
        var priorityByIdentifier: [NSUserInterfaceItemIdentifier: (direction: SortDirection, priority: Int)] = [:]
        for (priority, entry) in Self.presentedColumns(of: state, in: schema).enumerated() {
            guard let identifier = schema.identifier(for: entry.dataIndex) else { continue }
            priorityByIdentifier[identifier] = (entry.direction, priority + 1)
        }
        let isDefaultSort = state.source == .defaultSort

        for (columnIndex, column) in tableView.tableColumns.enumerated() {
            guard let cell = column.headerCell as? SortableHeaderCell else { continue }
            let entry = priorityByIdentifier[column.identifier]
            let newDirection = entry?.direction
            let newPriority = isDefaultSort ? nil : entry?.priority
            let newIsDefault = entry != nil && isDefaultSort
            cell.setAccessibilitySortDirection(Self.accessibilitySortDirection(for: newDirection))
            if cell.sortDirection != newDirection
                || cell.sortPriority != newPriority
                || cell.isDefaultSort != newIsDefault {
                cell.sortDirection = newDirection
                cell.sortPriority = newPriority
                cell.isDefaultSort = newIsDefault
                setNeedsDisplay(headerRect(ofColumn: columnIndex))
            }
        }
    }

    /// The sort entries the current result actually carries a column for, resolved by name.
    ///
    /// A sort keeps its entry when its column leaves the result, so that re-running a query that
    /// brings the column back restores the order. Its `columnIndex` is stale while it is away, and
    /// painting from that index put the chevron and the sort descriptor on whichever column had
    /// moved into the slot: `SELECT id, name, email` sorted on `email`, re-run as
    /// `SELECT id, name, phone`, marked `phone` as sorted over rows `phone` never ordered.
    private static func presentedColumns(
        of state: SortState,
        in schema: ColumnIdentitySchema
    ) -> [(name: String, dataIndex: Int, direction: SortDirection)] {
        state.columns.compactMap { sortColumn in
            guard let name = SortColumnResolver.columnName(for: sortColumn, displayColumns: schema.columnNames) else {
                return nil
            }
            /// The slot the entry already names wins whenever it still carries that name, because
            /// `dataIndex(forColumnName:)` answers a duplicate name with its last occurrence and
            /// `SELECT a.id, b.id` would otherwise mark and order the wrong one.
            if schema.columnName(for: sortColumn.columnIndex) == name {
                return (name, sortColumn.columnIndex, sortColumn.direction)
            }
            guard let dataIndex = schema.dataIndex(forColumnName: name) else { return nil }
            return (name, dataIndex, sortColumn.direction)
        }
    }

    private static func presentedState(of state: SortState, in schema: ColumnIdentitySchema) -> SortState {
        SortState(
            columns: presentedColumns(of: state, in: schema).map {
                SortColumn(columnIndex: $0.dataIndex, direction: $0.direction, columnName: $0.name)
            },
            source: state.source
        )
    }

    private static func accessibilitySortDirection(for direction: SortDirection?) -> NSAccessibilitySortDirection {
        switch direction {
        case .ascending: return .ascending
        case .descending: return .descending
        case nil: return .unknown
        }
    }

    /// Did the gesture `super.mouseDown` just consumed end as a click, or as a drag the user aborted?
    ///
    /// A `mouseDragged` override cannot answer this: `NSTableHeaderView.mouseDown` runs its own
    /// modal tracking loop and dequeues the drags itself, so the override is never called (measured,
    /// zero calls, including on a real reorder). An aborted drag also leaves column order and widths
    /// untouched, so those two comparisons cannot answer it either.
    ///
    /// On an unmodified click AppKit has already decided, because every data column carries a
    /// `sortDescriptorPrototype`: it rewrites `sortDescriptors` for a click and leaves them alone
    /// for a drag. Under a modifier AppKit does nothing at all (measured), so there is no signal to
    /// borrow and the distance between the press and the release is what is left.
    private static func gestureWasClick(
        modifierFlags: NSEvent.ModifierFlags,
        downLocationInWindow: NSPoint,
        descriptorsBeforeClick: [NSSortDescriptor],
        descriptorsAfterClick: [NSSortDescriptor]
    ) -> Bool {
        guard modifierFlags.isEmpty else {
            return releaseWasInPlace(downLocationInWindow: downLocationInWindow)
        }
        return descriptorsAfterClick != descriptorsBeforeClick
    }

    /// The release AppKit's tracking loop consumed. `NSApp.currentEvent` is that `leftMouseUp` by the
    /// time `super.mouseDown` returns, measured, so the press-to-release distance is available even
    /// though no `mouseDragged` was ever dispatched.
    private static func releaseWasInPlace(downLocationInWindow: NSPoint) -> Bool {
        guard let release = NSApp.currentEvent, release.type == .leftMouseUp else { return true }
        let up = release.locationInWindow
        return abs(up.x - downLocationInWindow.x) <= clickDragThreshold
            && abs(up.y - downLocationInWindow.y) <= clickDragThreshold
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
        let descriptorsBeforeClick = tableView.sortDescriptors
        let isMultiSort = modifierFlags.contains(.shift)

        super.mouseDown(with: event)

        let columnOrderChanged = tableView.tableColumns.map { $0.identifier } != originalColumnOrder
        let columnWidthsChanged = tableView.tableColumns.map { $0.width } != originalColumnWidths
        if columnOrderChanged || columnWidthsChanged {
            return
        }
        guard Self.gestureWasClick(
            modifierFlags: modifierFlags,
            downLocationInWindow: event.locationInWindow,
            descriptorsBeforeClick: descriptorsBeforeClick,
            descriptorsAfterClick: tableView.sortDescriptors
        ) else { return }

        if modifierFlags.contains(.command) && !modifierFlags.contains(.shift) {
            coordinator.extendColumnSelection(dataIndex)
            return
        }

        let schema = coordinator.identitySchema
        /// The cycle runs over the sort the current result can actually show. An entry whose column
        /// left the result keeps its slot in the model so that bringing the column back restores its
        /// order, but feeding that latent slot to the cycle made a click on the unsorted column now
        /// sitting there advance the vanished column's cycle instead of starting a new one.
        let transition = HeaderSortCycle.nextTransition(
            state: Self.presentedState(of: coordinator.currentSortState, in: schema),
            clickedColumn: dataIndex,
            isMultiSort: isMultiSort,
            firstClickDirection: coordinator.firstClickSortDirection
        )
        let newState = SortColumnResolver.stamped(transition.newState, displayColumns: schema.columnNames)

        /// Announced, not painted. The header is drawn from whatever the model ends up holding, via
        /// `DataGridView.syncSortState`. Painting here first meant a click the model then refused,
        /// which "Discard Unsaved Changes?" does on Cancel, left the chevron and the click cycle
        /// describing a sort that never ran.
        coordinator.delegate?.dataGridSortStateChanged(newState)
    }
}
