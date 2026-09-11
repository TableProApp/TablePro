//
//  ClosureMenuTarget.swift
//  TablePro
//

import AppKit

/// `NSMenuItem` holds its target weakly, so the closure needs an owner that outlives the menu.
/// `representedObject` is that owner: it is strong, it belongs to the item, and it goes when the
/// item does.
@MainActor
final class ClosureMenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        action()
    }

    static func item(title: String, isEnabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        let target = ClosureMenuTarget(action: action)
        item.target = target
        item.representedObject = target
        item.isEnabled = isEnabled
        return item
    }
}
