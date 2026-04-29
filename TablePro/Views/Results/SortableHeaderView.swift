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

    private var indicatorViews: [String: NSImageView] = [:]
    private static let ascendingImage = NSImage(named: NSImage.Name("NSAscendingSortIndicator"))
    private static let descendingImage = NSImage(named: NSImage.Name("NSDescendingSortIndicator"))

    func updateSortIndicators(state: SortState, schema: ColumnIdentitySchema) {
        let activeKeys: Set<String> = Set(state.columns.compactMap {
            schema.identifier(for: $0.columnIndex)?.rawValue
        })

        for (key, view) in indicatorViews where !activeKeys.contains(key) {
            view.removeFromSuperview()
            indicatorViews.removeValue(forKey: key)
        }

        for sortCol in state.columns {
            guard let identifier = schema.identifier(for: sortCol.columnIndex) else { continue }
            let view = indicatorViews[identifier.rawValue] ?? makeIndicatorView()
            view.image = sortCol.direction == .ascending ? Self.ascendingImage : Self.descendingImage
            view.setAccessibilityLabel(
                sortCol.direction == .ascending
                    ? String(localized: "Sort ascending")
                    : String(localized: "Sort descending")
            )
            if view.superview == nil {
                addSubview(view)
            }
            indicatorViews[identifier.rawValue] = view
        }

        repositionIndicators()
    }

    override func layout() {
        super.layout()
        repositionIndicators()
    }

    private func repositionIndicators() {
        guard let tableView = tableView else { return }
        let padding: CGFloat = 4

        for (key, view) in indicatorViews {
            let identifier = NSUserInterfaceItemIdentifier(key)
            let columnIndex = tableView.column(withIdentifier: identifier)
            guard columnIndex >= 0 else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            let columnRect = headerRect(ofColumn: columnIndex)
            let imageSize = view.image?.size ?? NSSize(width: 9, height: 6)
            view.frame = NSRect(
                x: columnRect.maxX - imageSize.width - padding,
                y: columnRect.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
        }
    }

    private func makeIndicatorView() -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.contentTintColor = .secondaryLabelColor
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }

    private static let clickDragThreshold: CGFloat = 4

    private var pendingClickStartLocation: NSPoint?
    private var dragOccurredDuringClick = false

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
