//
//  DataGridCellRegistry.swift
//  TablePro
//

import AppKit
import Foundation

@MainActor
final class DataGridCellRegistry {
    weak var accessoryDelegate: DataGridCellAccessoryDelegate?
    weak var textFieldDelegate: NSTextFieldDelegate?

    private(set) var nullDisplayString: String
    private var settingsObserver: NSObjectProtocol?

    private let rowNumberCellIdentifier = NSUserInterfaceItemIdentifier("RowNumberCellView")

    init() {
        nullDisplayString = AppSettingsManager.shared.dataGrid.nullDisplay
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .dataGridSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.nullDisplayString = AppSettingsManager.shared.dataGrid.nullDisplay
            }
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
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

    func dequeueCell(of kind: DataGridCellKind, in tableView: NSTableView) -> DataGridBaseCellView {
        let identifier: NSUserInterfaceItemIdentifier
        let cellType: DataGridBaseCellView.Type

        switch kind {
        case .text:
            identifier = DataGridTextCellView.reuseIdentifier
            cellType = DataGridTextCellView.self
        case .foreignKey:
            identifier = DataGridForeignKeyCellView.reuseIdentifier
            cellType = DataGridForeignKeyCellView.self
        case .dropdown:
            identifier = DataGridDropdownCellView.reuseIdentifier
            cellType = DataGridDropdownCellView.self
        case .boolean:
            identifier = DataGridBooleanCellView.reuseIdentifier
            cellType = DataGridBooleanCellView.self
        case .date:
            identifier = DataGridDateCellView.reuseIdentifier
            cellType = DataGridDateCellView.self
        case .json:
            identifier = DataGridJsonCellView.reuseIdentifier
            cellType = DataGridJsonCellView.self
        case .blob:
            identifier = DataGridBlobCellView.reuseIdentifier
            cellType = DataGridBlobCellView.self
        }

        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? DataGridBaseCellView {
            reused.nullDisplayString = nullDisplayString
            return reused
        }

        let cell = cellType.init(frame: .zero)
        cell.identifier = identifier
        cell.accessoryDelegate = accessoryDelegate
        cell.cellTextField.delegate = textFieldDelegate
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
                cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
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
