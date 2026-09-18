//
//  FavoriteDatabaseMenuDelegate.swift
//  TablePro
//

import AppKit

/// Whether the active database is a favorite, and which environment it carries, depends on the live
/// connection, so the submenu is filled when it opens. Built on the same shape as
/// `SchemaMenuDelegate`, including the responder-chain lookup that resolves the window the chosen
/// item will act on.
///
/// The menu bar is the keyboard path to this feature. The row star is hover-revealed and the
/// context menus need a right-click, so without this the whole feature is pointer-only.
@MainActor
final class FavoriteDatabaseMenuDelegate: NSObject, NSMenuDelegate {
    private static let setAction = #selector(MainSplitViewController.setFavoriteDatabaseEnvironment(_:))
    private static let removeAction = #selector(MainSplitViewController.removeFavoriteDatabase(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.target(forAction: Self.setAction, to: nil, from: nil) as? MainSplitViewController
        guard let actions = controller?.commandActions, actions.canFavoriteActiveDatabase else {
            addPlaceholder(to: menu)
            return
        }
        let state = FavoriteDatabaseSelectionState(environments: [actions.activeDatabaseFavoriteEnvironment])
        for item in FavoriteDatabaseMenu.environmentItems(for: state) {
            menu.addItem(environmentItem(item))
        }
        guard state.hasFavorite else { return }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: FavoriteDatabaseMenu.removeTitle, action: Self.removeAction, keyEquivalent: ""))
    }

    private func environmentItem(_ entry: FavoriteDatabaseMenu.EnvironmentItem) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: Self.setAction, keyEquivalent: "")
        item.target = nil
        item.representedObject = entry.environment.rawValue
        item.state = entry.isOn ? .on : .off
        return item
    }

    private func addPlaceholder(to menu: NSMenu) {
        let empty = NSMenuItem(title: String(localized: "No Database Selected"), action: nil, keyEquivalent: "")
        empty.isEnabled = false
        menu.addItem(empty)
    }

    /// Keeps AppKit's key-equivalent search from rebuilding the menu on every modified keystroke,
    /// which would query the favorites store for items that carry no key equivalent.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
