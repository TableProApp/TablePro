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

    /// The one exception, and the reason it is safe. A view-less item would carry the figure in
    /// `title`, and a title re-measures: written into one with `validateVisibleItems()` called, the
    /// group went 219pt, 233pt, 232pt, 251pt across `0 kB/s`, `145 kB/s`, `1.2 MB/s` and
    /// `888.8 MB/s`, walking its own midpoint 16pt and sliding the connection name beside it once a
    /// second. A view pinned to a width holds still: the group and field frames were byte-identical
    /// across the same four figures.
    ///
    /// What made the old hosted status item undroppable was that it had no width of its own to give
    /// back. This one is pinned to a width measured from the widest figure it can ever draw, so it
    /// never needs compressing, and it is only in the group at all for a connection whose bytes the
    /// app carries.
    @Test("The throughput readout is view-backed, and pinned to a width it cannot outgrow")
    func throughputReadoutIsPinned() throws {
        let owner = MainWindowToolbar()
        let field = try #require(owner.transportRateItem.view as? NSTextField)
        let pinned = field.constraints.filter { $0.firstAttribute == .width && $0.relation == .equal }
        let constant = try #require(pinned.first?.constant)

        #expect(pinned.count == 1, "The readout must carry exactly one width constraint")

        let font = try #require(field.font)
        for candidate in TransportRateLabel.widestCandidates {
            let width = (candidate as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= constant, "\"\(candidate)\" needs \(width)pt but the field is \(constant)pt")
        }
    }

    /// Bare text, no capsule, which is what Xcode does with the one comparable thing it ships: its
    /// Window Title/Activity readout draws as plain text beside the Back/Forward capsule, measured
    /// on a running Xcode. `isBordered` here would give the readout a platter of its own and make
    /// the centre three capsules for two controls and one number.
    @Test("The throughput readout wears no capsule")
    func throughputReadoutIsUnbordered() {
        #expect(!MainWindowToolbar().transportRateItem.isBordered)
    }

    /// Beside the centred pair, never inside it. A group is laid out around its own midpoint, so a
    /// readout among the subitems pushes the connection and database capsules off centre by half its
    /// width. Measured at 1400pt: as its own adjacent item the group sits at x=647.0 midX=772.8,
    /// byte-identical to carrying no readout at all.
    @Test("The readout sits beside the centred group, not inside it and not centred itself")
    func readoutIsAdjacentToTheCentre() throws {
        let owner = MainWindowToolbar()
        let group = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.connectionGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )

        #expect(!group.subitems.contains { $0 === owner.transportRateItem })
        #expect(!owner.managedToolbar.centeredItemIdentifiers.contains(TransportRateToolbarItem.identifier))

        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let centre = try #require(identifiers.firstIndex(of: MainWindowToolbar.connectionGroup))
        let readout = try #require(identifiers.firstIndex(of: TransportRateToolbarItem.identifier))
        #expect(readout == centre + 1, "The readout must follow the centred group immediately")
    }

    /// Emptying the readout's own group is how it leaves the toolbar. Measured, nothing else hides
    /// it cleanly: a hidden view keeps its 75pt and a zero-width constraint still leaves 24pt, and
    /// `NSToolbarItem.isHidden` is macOS 15 against a macOS 14 floor.
    @Test("A connection with no measurable transport shows no readout")
    func unmeasuredConnectionsCarryNoReadout() {
        #expect(MainWindowToolbar().transportRateGroup.subitems.isEmpty)
    }

    /// Back and forward hide when there is nowhere to go, which is a deliberate departure from
    /// Apple: measured on a running Xcode, its Back/Forward group keeps its full 75pt capsule with
    /// both segments DISABLED. Emptying the group is what hides it, and measured, doing so drops its
    /// platter and moves nothing else, the centred group included.
    @Test("Back and forward are absent with no history to walk")
    func navigationHidesWithNowhereToGo() {
        let owner = MainWindowToolbar()

        #expect(owner.navigationGroup.subitems.isEmpty)
        #expect(owner.navigationGroup.isNavigational)
    }

    /// Both arrows go together. Hiding one of a segmented pair leaves a lone half-capsule whose
    /// width changes on every step through the history.
    @Test("The navigation group is the whole pair or nothing")
    func navigationHidesAsAPair() throws {
        let owner = MainWindowToolbar()
        let vended = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.backForwardGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )

        #expect(vended === owner.navigationGroup, "The toolbar must show the instance that gets emptied")
        #expect(vended.subitems.isEmpty || vended.subitems.count == 2)
    }

    /// The readout is a readout: it publishes no action, so AppKit never validates it and it has no
    /// menu-bar command of its own. That is the trade the placement makes, and it is pinned here so
    /// a later change that gives it an action has to say so.
    ///
    /// It still gets an overflow entry, because the centred group is the first region AppKit sheds
    /// when the window narrows and the figure should not vanish with the controls beside it. The
    /// entry is disabled: there is nothing to click.
    @Test("The throughput readout claims no action but still reports in the overflow menu")
    func throughputReadoutIsInertButVisible() throws {
        let owner = MainWindowToolbar()
        let item = owner.transportRateItem

        #expect(item.action == nil)

        let entry = try #require(item.menuFormRepresentation)
        #expect(entry.action == nil)
        #expect(!entry.isEnabled)
        #expect(!entry.title.isEmpty)
    }

    /// An arrow glyph is what the field draws; it is not what the overflow entry or VoiceOver
    /// should be handed, because neither reads it as a direction.
    @Test("The overflow entry names the direction rather than drawing an arrow")
    func overflowEntryNamesTheDirection() throws {
        let owner = MainWindowToolbar()
        owner.transportRateItem.apply(rate: TransportRate(receivedPerSecond: 145_408, sentPerSecond: 0))
        let entry = try #require(owner.transportRateItem.menuFormRepresentation)

        #expect(!entry.title.contains("\u{2193}"))
        #expect(!entry.title.contains("\u{2191}"))
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
            #expect(item.visibilityPriority == expected, "\(identifier.rawValue)")
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
            #expect(subitem is StatefulToolbarItem, "\(subitem.itemIdentifier.rawValue)")
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
        let group = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.connectionGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )
        let connection = try #require(
            group.subitems.first { $0.itemIdentifier == MainWindowToolbar.connection }
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
    /// rewrite moved the sidebar's two lists out of the toolbar's segmented control, and a command
    /// with no toolbar item and no menu item is unreachable.
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
