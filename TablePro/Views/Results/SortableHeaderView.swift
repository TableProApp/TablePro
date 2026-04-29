//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit

enum HeaderSortAction: Equatable {
    case sort(columnIndex: Int, ascending: Bool, isMultiSort: Bool)
    case removeMultiSort(columnIndex: Int)
    case clear
}

struct HeaderSortTransition: Equatable {
    let action: HeaderSortAction
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
            return HeaderSortTransition(
                action: .sort(columnIndex: clickedColumn, ascending: true, isMultiSort: true),
                newState: newState
            )
        }

        let existing = state.columns[existingIndex]
        switch existing.direction {
        case .ascending:
            var newState = state
            newState.columns[existingIndex].direction = .descending
            return HeaderSortTransition(
                action: .sort(columnIndex: clickedColumn, ascending: false, isMultiSort: true),
                newState: newState
            )
        case .descending:
            var newState = state
            newState.columns.remove(at: existingIndex)
            return HeaderSortTransition(
                action: .removeMultiSort(columnIndex: clickedColumn),
                newState: newState
            )
        }
    }

    private static func singleSortTransition(state: SortState, clickedColumn: Int) -> HeaderSortTransition {
        guard let primary = state.columns.first, primary.columnIndex == clickedColumn else {
            var newState = SortState()
            newState.columns = [SortColumn(columnIndex: clickedColumn, direction: .ascending)]
            return HeaderSortTransition(
                action: .sort(columnIndex: clickedColumn, ascending: true, isMultiSort: false),
                newState: newState
            )
        }

        switch primary.direction {
        case .ascending:
            var newState = SortState()
            newState.columns = [SortColumn(columnIndex: clickedColumn, direction: .descending)]
            return HeaderSortTransition(
                action: .sort(columnIndex: clickedColumn, ascending: false, isMultiSort: false),
                newState: newState
            )
        case .descending:
            return HeaderSortTransition(action: .clear, newState: SortState())
        }
    }
}

@MainActor
final class SortableHeaderView: NSTableHeaderView {
    weak var coordinator: TableViewCoordinator?

    private static let clickDragThreshold: CGFloat = 4
    private static let resizeZoneWidth: CGFloat = 4

    private var pendingClickStartLocation: NSPoint?
    private var dragOccurredDuringClick = false
    private var mouseMovedTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tableView = tableView else { return }
        let zoneWidth = Self.resizeZoneWidth
        for (index, column) in tableView.tableColumns.enumerated() {
            guard column.resizingMask.contains(.userResizingMask) else { continue }
            let columnRect = headerRect(ofColumn: index)
            let cursorRect = NSRect(
                x: columnRect.maxX - zoneWidth,
                y: columnRect.minY,
                width: zoneWidth * 2,
                height: columnRect.height
            )
            addCursorRect(cursorRect, cursor: .resizeLeftRight)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseMovedTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseMovedTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let tableView = tableView else {
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if isInResizeZone(point, in: tableView) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func updateSortIndicators(state: SortState, schema: ColumnIdentitySchema) {
        guard let tableView = tableView else { return }

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

    static func isInResizeZone(
        point: NSPoint,
        columnEdges: [CGFloat],
        zoneWidth: CGFloat = SortableHeaderView.resizeZoneWidth
    ) -> Bool {
        columnEdges.contains { abs(point.x - $0) <= zoneWidth }
    }

    private func isInResizeZone(_ point: NSPoint, in tableView: NSTableView) -> Bool {
        let edges = tableView.tableColumns.enumerated().compactMap { index, column -> CGFloat? in
            guard column.resizingMask.contains(.userResizingMask) else { return nil }
            return headerRect(ofColumn: index).maxX
        }
        return Self.isInResizeZone(point: point, columnEdges: edges)
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
        if isInResizeZone(pointInHeader, in: tableView) {
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

        if let window {
            let cursorInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let cursorInHeader = convert(cursorInWindow, from: nil)
            if abs(cursorInHeader.x - pointInHeader.x) > Self.clickDragThreshold ||
                abs(cursorInHeader.y - pointInHeader.y) > Self.clickDragThreshold {
                return
            }
        }

        let isMultiSort = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        let transition = HeaderSortCycle.nextTransition(
            state: coordinator.currentSortState,
            clickedColumn: dataIndex,
            isMultiSort: isMultiSort
        )

        coordinator.currentSortState = transition.newState
        updateSortIndicators(state: transition.newState, schema: coordinator.identitySchema)
        dispatch(transition: transition, on: coordinator)
    }

    private func dispatch(transition: HeaderSortTransition, on coordinator: TableViewCoordinator) {
        switch transition.action {
        case .sort(let columnIndex, let ascending, let isMultiSort):
            coordinator.delegate?.dataGridSort(
                column: columnIndex,
                ascending: ascending,
                isMultiSort: isMultiSort
            )
        case .removeMultiSort(let columnIndex):
            coordinator.delegate?.dataGridRemoveSortColumn(columnIndex)
        case .clear:
            coordinator.delegate?.dataGridClearSort()
        }
    }
}
