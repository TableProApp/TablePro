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

    func resolveKind(
        columnIndex: Int,
        columnType: ColumnType?,
        isFKColumn: Bool,
        isDropdownColumn: Bool
    ) -> DataGridCellKind {
        if isFKColumn { return .foreignKey }
        if isDropdownColumn { return .dropdown }
        if let type = columnType {
            if type.isBooleanType { return .boolean }
            if type.isDateType { return .date }
            if type.isJsonType { return .json }
            if type.isBlobType { return .blob }
        }
        return .text
    }

    func dequeueCell(in tableView: NSTableView) -> DataGridCellView {
        if let reused = tableView.makeView(
            withIdentifier: DataGridCellView.reuseIdentifier,
            owner: nil
        ) as? DataGridCellView {
            reused.nullDisplayString = nullDisplayString
            return reused
        }

        let cell = DataGridCellView(frame: .zero)
        cell.identifier = DataGridCellView.reuseIdentifier
        cell.accessoryDelegate = accessoryDelegate
        cell.nullDisplayString = nullDisplayString
        return cell
    }

    func makeRowNumberCell(
        in tableView: NSTableView,
        row: Int,
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
            cellView = NSTableCellView()
            cellView.identifier = rowNumberCellIdentifier

            cell = NSTextField(labelWithString: "")
            cell.alignment = .right
            cell.font = ThemeEngine.shared.dataGridFonts.rowNumber
            cell.tag = DataGridFontVariant.rowNumber
            cell.textColor = .secondaryLabelColor
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)

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

        guard row >= 0 && row < cachedRowCount else {
            cell.stringValue = ""
            return cellView
        }

        cell.stringValue = "\(row + 1)"
        cell.textColor = visualState.isDeleted ? ThemeEngine.shared.colors.dataGrid.deletedText : .secondaryLabelColor
        cellView.setAccessibilityLabel(String(format: String(localized: "Row %d"), row + 1))
        cellView.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))

        return cellView
    }
}
