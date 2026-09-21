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
    @Test("No command is backed by a view")
    func noCommandIsViewBacked() {
        for item in vendedItems() {
            #expect(item.view == nil, "\(item.itemIdentifier.rawValue) must not be view-backed")
        }
    }

    /// Availability is `isEnabled`, never presence. Measured on three running Apple apps, Xcode,
    /// Finder in column view and System Settings all keep the 75pt Back/Forward capsule and dim the
    /// direction that has nowhere to go; the HIG says the same for the menu bar, "disable the action
    /// instead of hiding it".
    ///
    /// This asserts on the VENDED item and on a toolbar with no coordinator, which is the state a
    /// hidden pair would report. Testing the pure `ToolbarContextResolver.isEnabled` predicate
    /// cannot catch the regression this replaces: four such cases stayed green for the whole life
    /// of the hiding commit, because they never look at composition. The pair is offered by
    /// Customize Toolbar rather than the default set, and a user who puts it back gets it whole.
    @Test("Back and forward are present and dimmed, never absent")
    func navigationIsPresentAndDimmed() throws {
        let owner = MainWindowToolbar()
        let group = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.backForwardGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )

        #expect(group.subitems.count == 2, "The pair is installed unconditionally")
        #expect(group.subitems.map(\.itemIdentifier) == [MainWindowToolbar.navigateBack, MainWindowToolbar.navigateForward])
        /// What puts the pair on the leading edge, where the HIG keeps items that return to the
        /// previous document, once a user has dragged it in from Customize Toolbar. The default set
        /// no longer carries it; ⌃⌘[ and ⌃⌘] and the Actions pull-down on a table tab do instead.
        #expect(group.isNavigational)

        for subitem in group.subitems {
            #expect(!owner.validateToolbarItem(subitem), "With no connection each direction dims")
        }
    }

    /// A `title` on either subitem would split the shared platter into two capsules. Measured: two
    /// titled subitems draw two platters, untitled ones share a single platter spanning the group,
    /// which is the one capsule Finder, Xcode and System Settings all draw.
    @Test("Neither navigation arrow carries a title")
    func navigationArrowsShareOneCapsule() throws {
        let owner = MainWindowToolbar()
        let group = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.backForwardGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )

        for subitem in group.subitems {
            #expect(subitem.title.isEmpty, "\(subitem.itemIdentifier.rawValue) must not set a title")
        }
    }

    /// Finder ships 8 controls and Xcode 13. The default set was 17 hit targets behind 11
    /// identifiers, and the guard that stood here counted identifiers, which is how a two-segment
    /// control was added to a full titlebar and passed. So this counts what a pointer can hit, with
    /// every group vended and expanded to the subitems it draws. Spaces and tracking separators take
    /// no click and are not counted.
    @available(macOS 14.0, *)
    @Test("The default set is at most eight things to click")
    func defaultSetIsNotCrowded() {
        let owner = MainWindowToolbar()
        let spaces: Set<NSToolbarItem.Identifier> = [
            .flexibleSpace, .space, .sidebarTrackingSeparator, .inspectorTrackingSeparator,
        ]
        let targets = MainWindowToolbar.defaultItemIdentifiers
            .filter { !spaces.contains($0) }
            .map { identifier -> Int in
                let item = owner.toolbar(
                    owner.managedToolbar,
                    itemForItemIdentifier: identifier,
                    willBeInsertedIntoToolbar: true
                )
                return (item as? NSToolbarItemGroup).map { max($0.subitems.count, 1) } ?? 1
            }
            .reduce(0, +)
        #expect(targets <= 8, "default set has \(targets) hit targets")
    }

    /// The HIG's centre area is for "common, useful controls", and SwiftUI's `principal` placement
    /// names the shape: "the location field for a web browser is a principal item... This item
    /// takes precedent over a title." The connection and the container are this window's location
    /// field, and both are controls that open a chooser. Xcode centres the same shape, measured
    /// through its accessibility tree: a list of role "path" holding Active Scheme and Active Run
    /// Destination.
    ///
    /// Two top-level items, not a group. Measured on macOS 27, a popover anchored on a subitem
    /// raised `NSInvalidArgumentException` whenever its group was hidden or clipped, and a
    /// top-level item raised in none of 16 presentations across the same states.
    @Test("The connection and container are the centred principal pair, as two top-level items")
    func centredPairIsTwoTopLevelItems() throws {
        let owner = MainWindowToolbar()
        let pair: Set<NSToolbarItem.Identifier> = [MainWindowToolbar.connection, MainWindowToolbar.database]
        #expect(owner.managedToolbar.centeredItemIdentifiers == pair)

        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let connection = try #require(identifiers.firstIndex(of: MainWindowToolbar.connection))
        #expect(identifiers.indices.contains(connection + 1))
        #expect(identifiers[connection + 1] == MainWindowToolbar.database, "The pair centres as one run")

        for identifier in pair {
            let item = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
            #expect(item != nil)
            #expect(!(item is NSToolbarItemGroup), "\(identifier.rawValue) must not be a group")
        }
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
            let centred = identifier == MainWindowToolbar.connection || identifier == MainWindowToolbar.database
            let expected: NSToolbarItem.VisibilityPriority = centred ? .standard : .high
            #expect(item.visibilityPriority == expected, "\(identifier.rawValue)")
        }
    }

    /// Measured: an icon-only toolbar suppresses an item's label and still draws its title, which
    /// is what lets the centred pair read as words while every other item stays a glyph. A centred
    /// item with no title would be two anonymous glyphs in the middle of the window.
    @Test("The centred items carry a title, not just a label")
    func centredItemsCarryTitles() {
        let owner = MainWindowToolbar()
        for identifier in [MainWindowToolbar.connection, MainWindowToolbar.database] {
            let item = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
            #expect(item is StatefulToolbarItem, "\(identifier.rawValue)")
            #expect((item as? StatefulToolbarItem)?.titleProvider != nil, "\(identifier.rawValue)")
        }
    }

    /// The pull-down carries no action. Given one, AppKit splits the control into a body that sends
    /// it and a chevron that opens the menu, so a click on the body would open nothing. Its overflow
    /// entry is AppKit's: measured on macOS 27, an `NSMenuToolbarItem` answers with a fresh item over
    /// its own menu whatever was assigned, so a narrow window's overflow offers what the control
    /// would. If that ever changes, the overflow stops being filled, and this is where it shows.
    @Test("The Actions item opens a menu its delegate fills, from the control and from the overflow")
    func actionsItemIsAPullDown() throws {
        let owner = MainWindowToolbar()
        let item = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.actions,
                willBeInsertedIntoToolbar: true
            ) as? NSMenuToolbarItem
        )

        #expect(item.action == nil)
        #expect(item.menu.delegate === owner.actionsMenuDelegate)
        let overflow = try #require(item.menuFormRepresentation)
        #expect(overflow.submenu === item.menu)
        #expect(overflow.title == item.label)
        #expect(!item.label.isEmpty)
    }

    /// The commit control says what its tab commits. The palette, the overflow entry and the
    /// tooltip all read the label, so a Create Table tab offering to Save Changes is the defect.
    ///
    /// Vended with nothing staged on purpose: the label is the tab's, so a definition that does not
    /// validate yet still reads Create Table, and an edit that makes it valid cannot relabel the
    /// control and reflow a labelled titlebar.
    @Test("The commit control is labelled with the verb its tab commits with")
    func commitControlNamesItsVerb() throws {
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db_a"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }
        let owner = MainWindowToolbar()
        coordinator.tabManager.addCreateTableTab()
        #expect(coordinator.toolbarState.pendingChange == nil)
        owner.repoint(to: coordinator)

        let item = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.saveChanges,
                willBeInsertedIntoToolbar: true
            )
        )
        #expect(item.label == String(localized: "Create Table"))
        #expect(item.menuFormRepresentation?.title == String(localized: "Create Table"))

        coordinator.tabManager.addTab()
        coordinator.toolbarState.pendingChange = .createTable
        let query = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.saveChanges,
                willBeInsertedIntoToolbar: true
            )
        )
        #expect(query.label == String(localized: "Save Changes"), "A query tab saves, whatever is staged")
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

    /// An overflowed item survives only as its `menuFormRepresentation`, and AppKit writes that
    /// entry's image once when the item is vended, so a glyph that follows the connection left the
    /// previous engine's icon in the menu.
    ///
    /// Pushed from `refreshConnectionScopedItems` rather than from wherever the image is set.
    /// Measured: touching `menuFormRepresentation` before the item assigns its own materializes
    /// AppKit's default one, and the later assignment then does not carry the key equivalent or the
    /// validation mapping the toolbar put on it.
    @Test("The connection glyph reaches the overflow entry too")
    func engineGlyphReachesTheMenuForm() throws {
        let owner = MainWindowToolbar()
        let connection = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.connection,
                willBeInsertedIntoToolbar: true
            )
        )

        #expect(connection.image != nil)
        #expect(connection.menuFormRepresentation?.image === connection.image)
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
    /// rewrite moved the sidebar's two lists out of the toolbar's segmented control and into the
    /// sidebar's own scope control, which a collapsed sidebar takes away with it, so the menu bar is
    /// what keeps both lists reachable.
    ///
    /// The other relocated commands live in submenus their delegate fills on open, so they are
    /// checked where that is true of them: `safeModeSubmenuOffersEveryLevel` and
    /// `schemaSubmenuSurvivesItsDelegate`, and `dynamicSubmenusHaveDelegates` for the per-driver
    /// Session Context list, which legitimately holds a placeholder until a driver publishes one.
    @Test("The sidebar lists the toolbar used to own are menu-bar commands")
    func relocatedCommandsReachTheMenuBar() {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        var found: Set<Selector> = []
        collectSelectors(from: menu, into: &found)

        let relocated: [Selector] = [
            #selector(MainSplitViewController.showTablesSidebarTab(_:)),
            #selector(MainSplitViewController.showFavoritesSidebarTab(_:)),
        ]
        for selector in relocated {
            #expect(found.contains(selector), "\(NSStringFromSelector(selector)) has no menu-bar command")
        }
    }

    /// Import Data… takes the driver's first format, and the per-format list used to live only in
    /// the toolbar, which is not a menu-bar command. The Actions pull-down now offers the list under
    /// this same title, so the menu bar carries its twin, filled by the same class.
    @Test("File > Import offers the command and, right under it, the list of formats")
    func fileImportOffersTheFormatList() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let file = try #require(menu.items.first { $0.submenu?.title == String(localized: "File") }?.submenu)
        let importMenu = try #require(file.items.first { $0.title == String(localized: "Import") }?.submenu)
        let leaf = try #require(importMenu.items.first { $0.title == String(localized: "Import Data…") })
        let list = try #require(importMenu.items.first { $0.title == String(localized: "Import Data From") })

        #expect(leaf.action == #selector(MainSplitViewController.importData(_:)))
        #expect(leaf.submenu == nil)
        #expect(list.submenu?.delegate is ImportFormatMenuDelegate)
        #expect(importMenu.index(of: list) == importMenu.index(of: leaf) + 1)
    }

    /// Safe Mode's list does not depend on a session, so its delegate fills it every time and all
    /// six levels have to be there. A five-level list would silently strip a level from the only
    /// menu-bar route to it.
    @Test("The Safe Mode submenu offers every level")
    func safeModeSubmenuOffersEveryLevel() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let database = try #require(menu.items.first { $0.submenu?.title == String(localized: "Database") }?.submenu)
        let safeMode = try #require(
            database.items.first { $0.title == String(localized: "Safe Mode Level") }?.submenu
        )

        safeMode.delegate?.menuNeedsUpdate?(safeMode)

        let action = #selector(MainSplitViewController.setSafeModeLevel(_:))
        #expect(safeMode.items.filter { $0.action == action }.count == SafeModeLevel.allCases.count)
    }

    /// A delegate that clears the menu on open destroys anything added when the container was
    /// built, so a statically added item is gone the first time the submenu is used. The earlier
    /// version of this suite inspected the freshly built menu and passed while the shipped Schema
    /// submenu had no Open Schema Switcher command at all.
    @Test("The Schema submenu still offers its switcher after the delegate fills it")
    func schemaSubmenuSurvivesItsDelegate() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let database = try #require(menu.items.first { $0.submenu?.title == String(localized: "Database") }?.submenu)
        let schema = try #require(
            database.items.first { $0.title == String(localized: "Schema") }?.submenu
        )

        schema.delegate?.menuNeedsUpdate?(schema)

        #expect(
            schema.items.contains { $0.action == #selector(MainSplitViewController.openSchemaSwitcher(_:)) },
            "the switcher command has to survive menuNeedsUpdate"
        )
    }

    /// A dynamic submenu is empty until it opens, so a delegate that never runs is a submenu that
    /// is permanently empty and reads as a broken command.
    @Test("The relocated commands' submenus have a delegate to fill them")
    func dynamicSubmenusHaveDelegates() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let database = try #require(menu.items.first { $0.submenu?.title == String(localized: "Database") }?.submenu)

        for title in [String(localized: "Safe Mode Level"), String(localized: "Session Context")] {
            let submenu = try #require(database.items.first { $0.title == title }?.submenu, "\(title)")
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
    /// The chooser has one entry point, so nothing can reach it past the session gate. The centred
    /// chip did exactly that: its only condition was the engine's capability, so it opened the
    /// chooser over a session the health monitor had given up on while the button beside it and the
    /// menu command were both correctly disabled.
    @Test("One toolbar control opens the container chooser")
    func containerChooserHasOneEntryPoint() {
        let owner = MainWindowToolbar()
        let openers = MainWindowToolbar.allowedItemIdentifiers
            .compactMap {
                owner.toolbar(owner.managedToolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: true)
            }
            .flatMap { item -> [NSToolbarItem] in
                guard let group = item as? NSToolbarItemGroup else { return [item] }
                return [item] + group.subitems
            }
            .filter { $0.action == #selector(MainWindowToolbar.performOpenDatabaseSwitcher(_:)) }

        #expect(openers.count == 1)
        #expect(openers.first?.itemIdentifier == MainWindowToolbar.database)
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
