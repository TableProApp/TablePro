//
//  DataGridChevronCellView.swift
//  TablePro
//

import AppKit

class DataGridChevronCellView: DataGridBaseCellView {
    private lazy var chevronButton: CellChevronButton = AccessoryButtonFactory.makeChevronButton()

    override func installAccessory() {
        addSubview(chevronButton)
        NSLayoutConstraint.activate([
            chevronButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 10),
            chevronButton.heightAnchor.constraint(equalToConstant: 12),
        ])
        chevronButton.target = self
        chevronButton.action = #selector(handleChevronClick(_:))
    }

    override func updateAccessoryVisibility(content: DataGridCellContent, state: DataGridCellState) {
        let show = state.isEditable && !state.visualState.isDeleted
        chevronButton.isHidden = !show
        if show {
            chevronButton.cellRow = state.row
            chevronButton.cellColumnIndex = state.columnIndex
        } else {
            chevronButton.cellRow = -1
            chevronButton.cellColumnIndex = -1
        }
    }

    override func textFieldTrailingInset(for content: DataGridCellContent, state: DataGridCellState) -> CGFloat {
        let show = state.isEditable && !state.visualState.isDeleted
        return show ? -18 : -4
    }

    @objc
    private func handleChevronClick(_ sender: CellChevronButton) {
        accessoryDelegate?.dataGridCellDidClickChevron(row: sender.cellRow, columnIndex: sender.cellColumnIndex)
    }
}
