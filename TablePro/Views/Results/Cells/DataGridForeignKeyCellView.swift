//
//  DataGridForeignKeyCellView.swift
//  TablePro
//

import AppKit

final class DataGridForeignKeyCellView: DataGridBaseCellView {
    override class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dataCell.foreignKey")
    }

    private lazy var fkButton: FKArrowButton = AccessoryButtonFactory.makeFKArrowButton()

    override func installAccessory() {
        addSubview(fkButton)
        NSLayoutConstraint.activate([
            fkButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DataGridMetrics.cellHorizontalInset
            ),
            fkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            fkButton.widthAnchor.constraint(equalToConstant: 16),
            fkButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        fkButton.target = self
        fkButton.action = #selector(handleFKClick(_:))
    }

    override func updateAccessoryVisibility(content: DataGridCellContent, state: DataGridCellState) {
        let show = isAccessoryVisible(for: content)
        fkButton.isHidden = !show
        if show {
            fkButton.fkRow = state.row
            fkButton.fkColumnIndex = state.columnIndex
        } else {
            fkButton.fkRow = -1
            fkButton.fkColumnIndex = -1
        }
    }

    override func textFieldTrailingInset(for content: DataGridCellContent, state: DataGridCellState) -> CGFloat {
        isAccessoryVisible(for: content) ? -22 : -4
    }

    private func isAccessoryVisible(for content: DataGridCellContent) -> Bool {
        guard let raw = content.rawValue else { return false }
        return !raw.isEmpty
    }

    @objc
    private func handleFKClick(_ sender: FKArrowButton) {
        accessoryDelegate?.dataGridCellDidClickFKArrow(row: sender.fkRow, columnIndex: sender.fkColumnIndex)
    }
}
