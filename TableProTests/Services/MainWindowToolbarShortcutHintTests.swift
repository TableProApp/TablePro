import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

extension GlobalStateSuites {
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

        /// Back and Forward ride a group, so the delegate vends no standalone item for either. Resolving
        /// through the group is what the tests have to do, and it is also what the overflow menu and
        /// the customization palette do.
        private func vendSubitem(
            _ identifier: NSToolbarItem.Identifier,
            of groupIdentifier: NSToolbarItem.Identifier,
            from owner: MainWindowToolbar
        ) -> NSToolbarItem? {
            let group = vend(groupIdentifier, from: owner) as? NSToolbarItemGroup
            return group?.subitems.first { $0.itemIdentifier == identifier }
        }

        @Test(
            "A vended item takes its key equivalent from the user's binding, not a literal",
            .appSettings { $0.keyboard.setShortcut(.character("j", command: true, control: true), for: .quickSwitcher) }
        )
        func vendedItemFollowsCustomBinding() {
            let item = vend(MainWindowToolbar.quickSwitcher, from: MainWindowToolbar())
            let menuItem = item?.menuFormRepresentation
            #expect(menuItem?.keyEquivalent == "j")
            #expect(menuItem?.keyEquivalentModifierMask == [.command, .control])
        }

        @Test(
            "A vended item's tooltip names the user's binding",
            .appSettings { $0.keyboard.setShortcut(.character("j", command: true, control: true), for: .quickSwitcher) }
        )
        func vendedItemTooltipNamesCustomBinding() {
            let item = vend(MainWindowToolbar.quickSwitcher, from: MainWindowToolbar())
            #expect(item?.toolTip?.contains("⌃⌘J") == true)
        }

        /// The regression this suite exists for: an item vended before the rebind has to follow it.
        @Test(
            "An already-vended item follows a later rebind",
            .appSettings { $0.keyboard.resetToDefault(for: .quickSwitcher) }
        )
        func vendedItemFollowsLaterRebind() async throws {
            /// A private identifier with autosave off. Inserting into a toolbar named like the app's own
            /// writes an arrangement into the test host's defaults, which are the app's.
            let identifier = NSToolbar.Identifier("com.TablePro.tests.\(UUID().uuidString)")
            let owner = MainWindowToolbar(managedToolbar: NSToolbar(identifier: identifier))
            owner.managedToolbar.autosavesConfiguration = false
            guard let item = vend(MainWindowToolbar.quickSwitcher, from: owner) else {
                Issue.record("Toolbar did not vend the Open Quickly item")
                return
            }
            owner.managedToolbar.insertItem(withItemIdentifier: MainWindowToolbar.quickSwitcher, at: 0)

            var keyboard = AppSettingsManager.shared.keyboard
            keyboard.setShortcut(.character("j", command: true, control: true), for: .quickSwitcher)
            AppSettingsManager.shared.keyboard = keyboard

            let vendedItem = owner.managedToolbar.items.first {
                $0.itemIdentifier == MainWindowToolbar.quickSwitcher
            }
            /// The toolbar refreshes off the settings write rather than inside it, so the hop through
            /// the main run loop has to complete before the item can be read.
            try await waitUntil { vendedItem?.menuFormRepresentation?.keyEquivalent == "j" }
            #expect(vendedItem?.menuFormRepresentation?.keyEquivalentModifierMask == [.command, .control])
            #expect(vendedItem?.toolTip?.contains("⌃⌘J") == true)
            _ = item
        }

        @Test("An item with no shortcut keeps a plain tooltip and no key equivalent")
        func itemWithoutShortcutHasNoKeyEquivalent() {
            let owner = MainWindowToolbar()
            let item = vend(MainWindowToolbar.restorePreviousValues, from: owner)
            #expect(item?.menuFormRepresentation?.keyEquivalent == "")
            #expect(item?.toolTip?.isEmpty == false)
        }

        /// Back is reachable from `allItems()` only while it is installed in its group, and `allItems()`
        /// is the only channel that re-applies a rebind to a toolbar item. A commit that hid the pair by
        /// emptying the group took both arrows out of that walk, so a rebind reached the menu bar and
        /// stopped, leaving the toolbar advertising a key that no longer ran the command. `try #require`
        /// rather than optional chaining on purpose: the house style here passes vacuously when the
        /// subitem is absent, which is exactly the state this guards against.
        @Test(
            "A rebind reaches the navigation arrows",
            .appSettings { $0.keyboard.setShortcut(.character("j", command: true, control: true), for: .navigateBack) }
        )
        func navigationFollowsLaterRebind() throws {
            let item = try #require(
                vendSubitem(
                    MainWindowToolbar.navigateBack,
                    of: MainWindowToolbar.backForwardGroup,
                    from: MainWindowToolbar()
                ),
                "Back must be reachable through its group, or a rebind cannot find it"
            )
            #expect(item.toolTip?.contains("⌃⌘J") == true)
            #expect(item.menuFormRepresentation?.keyEquivalent == "j")
        }

        /// The Import item opens a submenu, so its menu form carries the submenu rather than a key.
        /// Writing a key equivalent onto it would put a shortcut on a row that only opens a menu.
        @Test("The Import item keeps its submenu and takes no key equivalent")
        func submenuItemTakesNoKeyEquivalent() {
            let owner = MainWindowToolbar()
            let item = vend(MainWindowToolbar.importTables, from: owner)
            #expect(item?.menuFormRepresentation?.submenu != nil)
            #expect(item?.menuFormRepresentation?.keyEquivalent == "")
            #expect(item?.toolTip?.isEmpty == false)
        }
    }
}
