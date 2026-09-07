//
//  MainWindowToolbarNativeContractTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The rules the toolbar rewrite exists to hold, each pinned because breaking it is what produced
/// the toolbar it replaced: a hosted SwiftUI status item AppKit could only drop whole, seventeen
/// controls in a titlebar that fits nine, and the connection, database and schema drawn twice.
@MainActor
struct MainWindowToolbarNativeContractTests {
    private func vendedItems() -> [NSToolbarItem] {
        let owner = MainWindowToolbar()
        return MainWindowToolbar.allowedItemIdentifiers
            .compactMap {
                owner.toolbar(owner.managedToolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: true)
            }
            .flatMap { item -> [NSToolbarItem] in
                guard let group = item as? NSToolbarItemGroup else { return [item] }
                return [item] + group.subitems
            }
    }

    /// The rule the whole rewrite rests on. A view-backed item is opaque to AppKit: the header says
    /// `validate()` does nothing for one ("items with custom views don't always have meaningful
    /// target/actions"), it answers no display-mode change, it cannot be compressed, and on a group
    /// the parent's view suppresses every subitem ("properties that get set on the parent toolbar
    /// item, such as label or view, apply to the entire item"). AppKit can only drop it whole, and
    /// it did: at 1200pt the hosted status item held its width while seven commands went to the
    /// overflow menu.
    @Test("No toolbar item is backed by a view")
    func noItemIsViewBacked() {
        for item in vendedItems() {
            #expect(item.view == nil, "\(item.itemIdentifier.rawValue) must not be view-backed")
        }
    }

    /// Finder ships 8 controls and Xcode 13. The default set was 17 plus a hosted status blob, and
    /// the HIG asks that items be chosen "deliberately to avoid overcrowding". Spaces do not count,
    /// because they cost no titlebar width of their own.
    @Test("The default set stays inside a titlebar")
    func defaultSetIsNotCrowded() {
        let spaces: Set<NSToolbarItem.Identifier> = [
            .flexibleSpace, .space, .sidebarTrackingSeparator, .inspectorTrackingSeparator,
        ]
        let controls = MainWindowToolbar.defaultItemIdentifiers.filter { !spaces.contains($0) }
        #expect(controls.count <= 12, "default set has \(controls.count) controls")
    }

    /// The HIG's centre area is for "common, useful controls", and SwiftUI's `principal` placement
    /// names the shape: "the location field for a web browser is a principal item... This item
    /// takes precedent over a title." The connection and the container are this window's location
    /// field, and both are controls that open a chooser. Xcode centres the same shape, measured
    /// through its accessibility tree: a list of role "path" holding Active Scheme and Active Run
    /// Destination.
    @Test("The connection and container are the centred principal item")
    func connectionGroupIsCentred() {
        let owner = MainWindowToolbar()
        #expect(owner.managedToolbar.centeredItemIdentifiers == [MainWindowToolbar.connectionGroup])
    }

    /// The centre is the first region AppKit sheds, and the two names it carries have no length
    /// limit, so without this every command went to the overflow menu at 1200pt while the scope
    /// chip held 314pt. Raising the commands rather than lowering the centre is what the HIG
    /// describes: trailing items "remain visible at all window sizes" and centre items
    /// "automatically collapse into the system-managed overflow menu".
    @Test("Commands outrank the centred item when space runs out")
    func commandsOutrankTheCentre() {
        let owner = MainWindowToolbar()
        for identifier in MainWindowToolbar.allowedItemIdentifiers {
            guard let item = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            ) else { continue }
            let expected: NSToolbarItem.VisibilityPriority =
                identifier == MainWindowToolbar.connectionGroup ? .standard : .high
            #expect(item.visibilityPriority == expected, identifier.rawValue)
        }
    }

    /// Measured: an icon-only toolbar suppresses an item's label and still draws its title, which
    /// is what lets the centred pair read as words while every other item stays a glyph. A centred
    /// item with no title would be two anonymous glyphs in the middle of the window.
    @Test("The centred items carry a title, not just a label")
    func centredItemsCarryTitles() throws {
        let owner = MainWindowToolbar()
        let group = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.connectionGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )
        #expect(group.subitems.count == 2)
        for subitem in group.subitems {
            #expect(subitem is StatefulToolbarItem, subitem.itemIdentifier.rawValue)
        }
    }

    /// The Safe Mode glyph and its tooltip both name the level, because the glyph alone cannot:
    /// `lock` and `lock.open` differ by a few pixels and VoiceOver reads no image at all. Writing a
    /// bare `toolTip` after `levelProvider` used to overwrite it permanently, since the item only
    /// rewrites the tooltip when the level it applied changes.
    @Test("The Safe Mode item's tooltip names the level, not just the control")
    func safeModeTooltipNamesTheLevel() throws {
        let owner = MainWindowToolbar()
        let item = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.safeMode,
                willBeInsertedIntoToolbar: true
            ) as? SafeModeToolbarItem
        )
        let tooltip = try #require(item.toolTip)
        #expect(tooltip.contains(SafeModeLevel.silent.displayName))
        #expect(item.image != nil)
    }

    /// Icon-only is the default because that is what Apple's own toolbars ship and what keeps the
    /// titlebar one row tall; AppKit's own default is icon-and-label. Measured on macOS 27: an
    /// autosaved display mode is restored when the toolbar reaches its window, which is after
    /// `init`, so writing it here sets the default without overruling a reader who changed it.
    @Test("A new toolbar is icon-only, and the user can still change it")
    func displayModeDefaultsToIconOnly() {
        let owner = MainWindowToolbar()
        #expect(owner.managedToolbar.displayMode == .iconOnly)
        #expect(owner.managedToolbar.autosavesConfiguration)
        #expect(owner.managedToolbar.allowsUserCustomization)
    }

    /// The HIG's macOS rule: "Make every toolbar item available as a command in the menu bar." The
    /// rewrite moved four things out of the toolbar, and a command with no toolbar item and no menu
    /// item is unreachable. Snowflake's warehouse and role were exactly that even before the
    /// rewrite: they existed only inside the hosted connection group, so a window narrow enough to
    /// clip that group could not change either.
    @Test("Everything the toolbar stopped offering is a menu-bar command")
    func relocatedCommandsReachTheMenuBar() {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        var found: Set<Selector> = []
        collectSelectors(from: menu, into: &found)

        let relocated: [Selector] = [
            #selector(MainSplitViewController.setSafeModeLevel(_:)),
            #selector(MainSplitViewController.switchSessionContext(_:)),
            #selector(MainSplitViewController.showTablesSidebarTab(_:)),
            #selector(MainSplitViewController.showFavoritesSidebarTab(_:)),
            #selector(MainSplitViewController.openSchemaSwitcher(_:)),
        ]
        for selector in relocated {
            #expect(found.contains(selector), "\(NSStringFromSelector(selector)) has no menu-bar command")
        }
    }

    /// A dynamic submenu is empty until it opens, so a delegate that never runs is a submenu that
    /// is permanently empty and reads as a broken command.
    @Test("The relocated commands' submenus have a delegate to fill them")
    func dynamicSubmenusHaveDelegates() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let database = try #require(menu.items.first { $0.submenu?.title == String(localized: "Database") }?.submenu)

        for title in [String(localized: "Safe Mode"), String(localized: "Session Context")] {
            let submenu = try #require(database.items.first { $0.title == title }?.submenu, title)
            #expect(submenu.delegate != nil, "\(title) needs a delegate to fill it")
        }
    }

    private func collectSelectors(from menu: NSMenu, into found: inout Set<Selector>) {
        for item in menu.items {
            if let action = item.action { found.insert(action) }
            if let submenu = item.submenu { collectSelectors(from: submenu, into: &found) }
        }
    }
}

/// The connection, the database and the schema are drawn once each, by whatever already owns them.
/// Before the rewrite the window title read "TablePro" while a capsule 200pt away read "TablePro",
/// the window subtitle read "tablepro_license · public" while a chip beside it read
/// "tablepro_license › public", and a cylinder button and a cylinder chip opened the same chooser
/// through two entry points with two different gates.
@MainActor
struct MainWindowToolbarSingleSourceTests {
    /// The switcher has one entry point, so a caller cannot reach it past the session gate. The
    /// centred chip did exactly that: its only condition was the engine's capability, so it opened
    /// the chooser over a session the health monitor had given up on while the button beside it and
    /// the menu command were both correctly disabled.
    @Test("One command opens the container chooser, for either scope")
    func containerChooserHasOneEntryPoint() {
        let sources = MainWindowToolbar.allowedItemIdentifiers.filter {
            $0 == MainWindowToolbar.database
        }
        #expect(sources.count == 1)
    }

    /// The container the window is browsing is drawn once, by the centred control that switches
    /// it. The window subtitle used to carry the same two words a few hundred points away, which
    /// is the duplication SwiftUI's `principal` documentation means by "takes precedent over a
    /// title". The title still names the tab, which is a different fact.
    @Test("The window keeps no subtitle for the toolbar to duplicate")
    func windowCarriesNoSubtitle() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            connection: TestFixtures.makeConnection(database: "myapp", type: .postgresql),
            tab: nil,
            hasTabs: true,
            queryLanguageName: "SQL"
        )
        #expect(resolved.subtitle.isEmpty)
    }

    /// Every item still needs a label, which is what the customization palette and the overflow
    /// menu show. An item with none is a blank tile the user cannot identify.
    @Test("Every item carries a palette-visible label")
    func everyItemHasALabel() {
        let owner = MainWindowToolbar()
        let labels = MainWindowToolbar.allowedItemIdentifiers
            .compactMap {
                owner.toolbar(owner.managedToolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: true)
            }
            .map(\.label)

        for label in labels {
            #expect(!label.isEmpty, "every item needs a palette-visible label")
        }
    }
}
