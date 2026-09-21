//
//  ConnectionActionsMenuDelegate.swift
//  TablePro
//

import AppKit

/// Builds the Actions pull-down each time it opens, from `ConnectionActionsMenuResolver` and from
/// nothing else.
///
/// Built on open rather than on every context change. The menu is only read while it is open, and
/// `menuNeedsUpdate` is measured to fire exactly once per real open, so a tab switch costs it
/// nothing and a menu that has been opened once can never describe a tab the window has left.
///
/// No command carries a target. AppKit resolves each one through the responder chain to the
/// window's controller and asks that controller's `validateMenuItem`, which is the path the menu bar
/// already takes for the same commands, so the pull-down needs no enablement table of its own and
/// cannot disagree with the menu bar. A command targeted at the toolbar would be validated by
/// `MainWindowToolbar.validateMenuItem` instead, which answers true for every action it did not
/// build, and the whole menu would ship enabled. A submenu's own row is the exception AppKit makes
/// itself: measured, assigning `submenu` sets the row's action to `submenuAction:` and its target
/// to the submenu.
@MainActor
internal final class ConnectionActionsMenuDelegate: NSObject, NSMenuDelegate {
    private let context: @MainActor () -> ToolbarContext
    private let importFormats: ImportFormatMenuDelegate
    private let modes = ContentModeMenuDelegate()

    internal init(
        importFormats: ImportFormatMenuDelegate,
        context: @escaping @MainActor () -> ToolbarContext
    ) {
        self.importFormats = importFormats
        self.context = context
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in items(for: context(), keyboard: AppSettingsManager.shared.keyboard) {
            menu.addItem(item)
        }
    }

    /// The menu for a context, sections divided by separators. Separate from `menuNeedsUpdate` so
    /// the whole shape can be read without an open menu or a window.
    internal func items(for context: ToolbarContext, keyboard: KeyboardSettings) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, section) in ConnectionActionsMenuResolver.sections(context).enumerated() {
            if index > 0 { items.append(.separator()) }
            items.append(contentsOf: section.entries.map { item(for: $0, keyboard: keyboard) })
        }
        return items
    }

    /// The chord an entry names is drawn from the user's own binding, so a rebind in Settings
    /// reaches this menu on its next open. It is shown, not claimed: `menuHasKeyEquivalent` below
    /// keeps AppKit's key-equivalent search out of this menu, so the menu bar stays the one owner.
    ///
    /// A submenu's row takes no action and no key equivalent, because it can draw neither. That is
    /// why Import Data… is a leaf of its own beside the format list, carrying ⇧⌘I, the way File >
    /// Import draws the same two rows.
    private func item(for entry: ActionsMenuEntry, keyboard: KeyboardSettings) -> NSMenuItem {
        switch entry.role {
        case let .command(selector, shortcut):
            let item = NSMenuItem(title: entry.title, action: selector, keyEquivalent: "")
            item.target = nil
            if let shortcut {
                MenuItemFactory.apply(shortcut: shortcut, keyboard: keyboard, to: item)
            }
            return item
        case let .submenu(kind):
            let root = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: entry.title)
            submenu.delegate = delegate(for: kind)
            root.submenu = submenu
            return root
        }
    }

    private func delegate(for kind: ActionsSubmenuKind) -> any NSMenuDelegate {
        switch kind {
        case .importFormats:
            return importFormats
        case .mode:
            return modes
        }
    }

    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
