//
//  BooleanCellEditor.swift
//  TablePro
//
//  Custom cell editor for YES/NO boolean values with dropdown.
//

import AppKit

/// NSPopUpButton configured for YES/NO boolean editing
final class BooleanCellEditor: NSPopUpButton {
    var onValueChanged: ((String) -> Void)?
    var initialValue: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        removeAllItems()
        addItem(withTitle: "YES")
        addItem(withTitle: "NO")

        target = self
        action = #selector(valueChanged)

        // Style to match text fields
        bezelStyle = .texturedSquare
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    @objc private func valueChanged() {
        guard let selected = titleOfSelectedItem else { return }
        onValueChanged?(selected)
    }

    func selectValue(_ value: String?) {
        initialValue = value
        let normalized = value?.uppercased() ?? "NO"

        if normalized == "YES" || normalized == "1" || normalized == "TRUE" {
            selectItem(withTitle: "YES")
        } else {
            selectItem(withTitle: "NO")
        }
    }
}

/// Custom field editor that provides dropdown editing for boolean columns
final class BooleanFieldEditor: NSTextView {
    var popupButton: BooleanCellEditor?
    var onComplete: ((String) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()

        // Create and show popup button
        if popupButton == nil {
            let popup = BooleanCellEditor(frame: bounds)
            popup.autoresizingMask = [.width, .height]
            popup.onValueChanged = { [weak self] value in
                self?.onComplete?(value)
                self?.window?.makeFirstResponder(nil)
            }

            addSubview(popup)
            popupButton = popup

            // Pull down the menu immediately
            DispatchQueue.main.async {
                popup.performClick(nil)
            }
        }

        return result
    }

    override func resignFirstResponder() -> Bool {
        popupButton?.removeFromSuperview()
        popupButton = nil
        return super.resignFirstResponder()
    }
}
