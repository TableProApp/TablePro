//
//  SidebarPullDownButton.swift
//  TablePro
//

import AppKit

@MainActor
internal final class SidebarPullDownButton: NSPopUpButton {
    internal var fill: @MainActor (NSMenu) -> Void

    // The cell draws from the item at index 0, not from `image`. It stays action-less and enabled:
    // a disabled label item dims the whole button.
    private let labelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    internal init(
        symbolName: String,
        label: String,
        identifier: String,
        fill: @escaping @MainActor (NSMenu) -> Void
    ) {
        self.fill = fill
        super.init(frame: .zero, pullsDown: true)
        labelItem.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        isBordered = false
        imagePosition = .imageOnly
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        toolTip = label
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(labelItem)
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarPullDownButton does not support NSCoder init")
    }
}

extension SidebarPullDownButton: NSMenuDelegate {
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
        menu.insertItem(labelItem, at: 0)
    }

    // No item carries a key equivalent, so a key-equivalent search never needs to rebuild the menu.
    internal func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
