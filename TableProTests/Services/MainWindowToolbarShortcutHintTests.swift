//
//  MainWindowToolbarShortcutHintTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// A toolbar item's tooltip and its overflow-menu key equivalent are written once, when the
/// delegate vends the item, and AppKit never revisits either. Both used to be spelled out as
/// literals beside the action, so rebinding a shortcut in Settings reached the menu bar and
/// stopped there, leaving the toolbar advertising a key that no longer ran the command.
@MainActor
struct MainWindowToolbarShortcutHintTests {
    private func vend(_ identifier: NSToolbarItem.Identifier, from owner: MainWindowToolbar) -> NSToolbarItem? {
        owner.toolbar(
            owner.managedToolbar,
            itemForItemIdentifier: identifier,
            willBeInsertedIntoToolbar: true
        )
    }

    private func withKeyboard(
        _ key: BoundKey,
        for action: ShortcutAction,
        _ body: (MainWindowToolbar) throws -> Void
    ) rethrows {
        let previous = AppSettingsManager.shared.keyboard
        defer { AppSettingsManager.shared.keyboard = previous }

        var keyboard = previous
        keyboard.setShortcut(key, for: action)
        AppSettingsManager.shared.keyboard = keyboard

        try body(MainWindowToolbar())
    }

    @Test("A vended item takes its key equivalent from the user's binding, not a literal")
    func vendedItemFollowsCustomBinding() {
        withKeyboard(.character("j", command: true, control: true), for: .quickSwitcher) { owner in
            let item = vend(MainWindowToolbar.quickSwitcher, from: owner)
            let menuItem = item?.menuFormRepresentation
            #expect(menuItem?.keyEquivalent == "j")
            #expect(menuItem?.keyEquivalentModifierMask == [.command, .control])
        }
    }

    @Test("A vended item's tooltip names the user's binding")
    func vendedItemTooltipNamesCustomBinding() {
        withKeyboard(.character("j", command: true, control: true), for: .quickSwitcher) { owner in
            let item = vend(MainWindowToolbar.quickSwitcher, from: owner)
            #expect(item?.toolTip?.contains("⌃⌘J") == true)
        }
    }

    /// The regression this suite exists for: an item vended before the rebind has to follow it.
    @Test("An already-vended item follows a later rebind")
    func vendedItemFollowsLaterRebind() {
        let previous = AppSettingsManager.shared.keyboard
        defer { AppSettingsManager.shared.keyboard = previous }

        AppSettingsManager.shared.keyboard = {
            var keyboard = previous
            keyboard.resetToDefault(for: .quickSwitcher)
            return keyboard
        }()

        let owner = MainWindowToolbar()
        guard let item = vend(MainWindowToolbar.quickSwitcher, from: owner) else {
            Issue.record("Toolbar did not vend the Open Quickly item")
            return
        }
        owner.managedToolbar.insertItem(withItemIdentifier: MainWindowToolbar.quickSwitcher, at: 0)

        var keyboard = AppSettingsManager.shared.keyboard
        keyboard.setShortcut(.character("j", command: true, control: true), for: .quickSwitcher)
        AppSettingsManager.shared.keyboard = keyboard

        let vendedItem = owner.managedToolbar.items.first { $0.itemIdentifier == MainWindowToolbar.quickSwitcher }
        /// The toolbar refreshes off the settings write rather than inside it, so the hop through
        /// the main run loop has to complete before the item can be read.
        #expect(spinRunLoopUntil { vendedItem?.menuFormRepresentation?.keyEquivalent == "j" })
        #expect(vendedItem?.menuFormRepresentation?.keyEquivalentModifierMask == [.command, .control])
        #expect(vendedItem?.toolTip?.contains("⌃⌘J") == true)
        _ = item
    }

    private func spinRunLoopUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    @Test("An item with no shortcut keeps a plain tooltip and no key equivalent")
    func itemWithoutShortcutHasNoKeyEquivalent() {
        let owner = MainWindowToolbar()
        let item = vend(MainWindowToolbar.dashboard, from: owner)
        #expect(item?.menuFormRepresentation?.keyEquivalent == "")
        #expect(item?.toolTip?.isEmpty == false)
    }

    /// The Import item opens a submenu, so its menu form carries the submenu rather than a key.
    /// Writing a key equivalent onto it would put a shortcut on a row that only opens a menu.
    /// It is only ever vended inside the Export & Import group, never on its own.
    @Test("The Import item keeps its submenu and takes no key equivalent")
    func submenuItemTakesNoKeyEquivalent() {
        let owner = MainWindowToolbar()
        let group = vend(MainWindowToolbar.exportImportGroup, from: owner) as? NSToolbarItemGroup
        let item = group?.subitems.first { $0.itemIdentifier == MainWindowToolbar.importTables }
        #expect(item?.menuFormRepresentation?.submenu != nil)
        #expect(item?.menuFormRepresentation?.keyEquivalent == "")
        #expect(item?.toolTip?.isEmpty == false)
    }
}
