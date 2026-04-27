//
//  BooleanCellView.swift
//  TablePro
//

import AppKit

@MainActor
final class BooleanCellView: DataGridCellView {
    var cellRow: Int = -1
    var cellColumnIndex: Int = -1

    private(set) lazy var checkbox: NSButton = {
        let button = NSButton()
        button.setButtonType(.switch)
        button.allowsMixedState = true
        button.title = ""
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.focusRingType = .none
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installCheckbox()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installCheckbox()
    }

    private func installCheckbox() {
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
