//
//  AccessoryButtons.swift
//  TablePro
//

import AppKit

@MainActor
final class FKArrowButton: NSButton {
    var fkRow: Int = -1
    var fkColumnIndex: Int = -1
}

@MainActor
final class CellChevronButton: NSButton {
    var cellRow: Int = -1
    var cellColumnIndex: Int = -1
}

@MainActor
enum AccessoryButtonFactory {
    static func makeFKArrowButton() -> FKArrowButton {
        let button = FKArrowButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: "arrow.right.circle.fill",
            accessibilityDescription: String(localized: "Navigate to referenced row")
        )
        button.contentTintColor = .tertiaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.imageScaling = .scaleProportionallyDown
        button.isHidden = true
        return button
    }

    static func makeChevronButton() -> CellChevronButton {
        let chevron = CellChevronButton()
        chevron.bezelStyle = .inline
        chevron.isBordered = false
        chevron.image = NSImage(
            systemSymbolName: "chevron.up.chevron.down",
            accessibilityDescription: String(localized: "Open editor")
        )
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.imageScaling = .scaleProportionallyDown
        chevron.isHidden = true
        return chevron
    }
}
