//
//  SortableHeaderView.swift
//  TablePro
//

import AppKit

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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift),
              let tableView = tableView,
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

        let existing = coordinator.currentSortState.columns.first(where: { $0.columnIndex == dataIndex })
        let ascending = existing == nil
        coordinator.delegate?.dataGridSort(column: dataIndex, ascending: ascending, isMultiSort: true)
    }
}
