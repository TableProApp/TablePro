//
//  DataGridCellRegistry.swift
//  TablePro
//

import AppKit
import Combine
import Foundation

@MainActor
final class DataGridCellRegistry {
    weak var accessoryDelegate: DataGridCellAccessoryDelegate?

    private(set) var nullDisplayString: String
    private(set) var palette: DataGridCellPalette
    private var settingsCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?

    private let rowNumberCellIdentifier = NSUserInterfaceItemIdentifier("RowNumberCellView")

    init() {
        nullDisplayString = AppSettingsManager.shared.dataGrid.nullDisplay
        palette = ThemeEngine.shared.dataGridCellPalette
        settingsCancellable = AppEvents.shared.dataGridSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.nullDisplayString = AppSettingsManager.shared.dataGrid.nullDisplay
            }
        themeCancellable = AppEvents.shared.themeChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.palette = ThemeEngine.shared.dataGridCellPalette
            }
    }


    func makeRowNumberCell(
        in tableView: NSTableView,
        row: Int,
        pageOffset: Int,
        cachedRowCount: Int,
        visualState: RowVisualState
    ) -> NSView {
        let cellView: NSTableCellView
        let cell: NSTextField

        if let reused = tableView.makeView(withIdentifier: rowNumberCellIdentifier, owner: nil) as? NSTableCellView,
           let textField = reused.textField {
            cellView = reused
            cell = textField
            cell.font = ThemeEngine.shared.dataGridFonts.rowNumber
        } else {
            cellView = DataGridRowNumberCellView()
            cellView.identifier = rowNumberCellIdentifier

            cell = NSTextField(labelWithString: "")
            cell.alignment = .right
            cell.font = ThemeEngine.shared.dataGridFonts.rowNumber
            cell.tag = DataGridFontVariant.rowNumber
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)
            cell.alphaValue = 0

            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(
                    equalTo: cellView.leadingAnchor,
                    constant: DataGridMetrics.cellHorizontalInset
                ),
                cell.trailingAnchor.constraint(
                    equalTo: cellView.trailingAnchor,
                    constant: -DataGridMetrics.cellHorizontalInset
                ),
                cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        cell.textColor = rowNumberColor(for: visualState)
        guard row >= 0 && row < cachedRowCount else {
            cell.stringValue = ""
            return cellView
        }

        let displayNumber = row + pageOffset + 1
        cell.stringValue = "\(displayNumber)"
        cellView.setAccessibilityLabel(String(format: String(localized: "Row %d"), displayNumber))
        cellView.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))

        return cellView
    }

    func rowNumberColor(for visualState: RowVisualState) -> NSColor {
        visualState.isDeleted ? palette.deletedRowText : palette.rowNumberText
    }
}

/// The row-number cell, mounted under the pinned row gutter, which paints every visible number.
///
/// Its number would show beside the gutter while a sideways bounce slides the column out from under
/// it, so the field draws at zero alpha. Zero alpha keeps the field in the accessibility tree, where
/// `isHidden` would drop it. It is also the only view a row drag can build its image from, so the
/// drag image is taken with the field shown.
final class DataGridRowNumberCellView: NSTableCellView {
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let textField else { return super.draggingImageComponents }
        let alpha = textField.alphaValue
        textField.alphaValue = 1
        defer { textField.alphaValue = alpha }
        return super.draggingImageComponents
    }
}
