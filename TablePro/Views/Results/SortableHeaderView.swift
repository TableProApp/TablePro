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

    private var pendingClickStartLocation: NSPoint?
    private var dragOccurredDuringClick = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
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
        coordinator.delegate?.dataGridSortStateChanged(transition.newState)
    }
}
