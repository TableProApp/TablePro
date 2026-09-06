//
//  SidebarViewOptionsButton.swift
//  TablePro
//

import AppKit

/// The View Options control in the sidebar's filter row.
///
/// `NSPopUpButton` in pull-down mode rather than a plain `NSButton` carrying a menu: a button's
/// `menu` opens on a secondary click only, and driving a menu from a button's action would give up
/// the keyboard activation and the menu-button accessibility role the pull-down has for free.
///
/// Measured on macOS 27: an `NSPopUpButton` ignores its own `image`, because the cell draws from the
/// menu, so the symbol goes on the item in the pull-down's label slot at index 0. That item is the
/// label and never appears among the choices.
@MainActor
internal final class SidebarViewOptionsButton: NSPopUpButton {
    private let labelItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        return item
    }()

    internal init() {
        super.init(frame: .zero, pullsDown: true)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        imagePosition = .imageOnly
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        setAccessibilityIdentifier("sidebar-view-options")
        setAccessibilityLabel(String(localized: "View Options"))
        toolTip = String(localized: "View Options")
        let options = NSMenu()
        options.delegate = self
        menu = options
        rebuild(options)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarViewOptionsButton does not support NSCoder init")
    }

    private func rebuild(_ menu: NSMenu) {
        SidebarMenuBuilder.fill(
            menu,
            with: SidebarViewOptionsMenu.currentSections(),
            target: self,
            action: #selector(performViewOption(_:))
        )
        menu.insertItem(labelItem, at: 0)
    }

    /// These settle how every object list draws, not this connection's, so the control writes the
    /// setting and nothing else. Each mounted tree repaints from its own observation of the same
    /// setting, which is what lets the same change arrive from here, from the empty-area menu and
    /// from Settings without three separate notifications.
    @objc
    private func performViewOption(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarMenuCommandBox<SidebarMenuCommand> else { return }
        switch box.command {
        case .toggleObjectIcons:
            AppSettingsManager.shared.general.showObjectIcons.toggle()
        case .toggleObjectComments:
            AppSettingsManager.shared.general.showObjectComments.toggle()
        case .setRowSize(let size):
            AppSettingsManager.shared.general.sidebarRowSize = size
        default:
            return
        }
    }
}

extension SidebarViewOptionsButton: NSMenuDelegate {
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }
}
