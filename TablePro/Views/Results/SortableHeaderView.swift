//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit

enum HeaderSortAction: Equatable {
    case sort(columnIndex: Int, ascending: Bool, isMultiSort: Bool)
    case clear
}

enum HeaderSortCycle {
    static func nextAction(
        state: SortState,
        clickedColumn: Int,
        isMultiSort: Bool
    ) -> HeaderSortAction {
        if isMultiSort {
            let alreadyPresent = state.columns.contains(where: { $0.columnIndex == clickedColumn })
            return .sort(columnIndex: clickedColumn, ascending: !alreadyPresent, isMultiSort: true)
        }

        guard let primary = state.columns.first, primary.columnIndex == clickedColumn else {
            return .sort(columnIndex: clickedColumn, ascending: true, isMultiSort: false)
        }

        switch primary.direction {
        case .ascending:
            return .sort(columnIndex: clickedColumn, ascending: false, isMultiSort: false)
        case .descending:
            return .clear
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

        let isMultiSort = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        let action = HeaderSortCycle.nextAction(
            state: coordinator.currentSortState,
            clickedColumn: dataIndex,
            isMultiSort: isMultiSort
        )

        switch action {
        case .sort(let columnIndex, let ascending, let isMultiSort):
            coordinator.delegate?.dataGridSort(
                column: columnIndex,
                ascending: ascending,
                isMultiSort: isMultiSort
            )
        case .clear:
            coordinator.delegate?.dataGridClearSort()
        }
    }
}
