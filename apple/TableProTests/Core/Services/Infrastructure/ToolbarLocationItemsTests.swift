//
//  ToolbarLocationItemsTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The connection and database capsules a General setting takes out of the toolbar, where the tree,
/// the query bar and the tab titles already name both. Written once per change of the setting, like
/// the Objects buttons, so what a person does with Customize Toolbar afterwards stays.
@MainActor
struct ToolbarLocationItemsTests {
    private static let connection = MainWindowToolbar.connection
    private static let database = MainWindowToolbar.database

    /// The default arrangement without the sidebar's divider, which only a split view window can hold.
    private static let defaultArrangement: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .flexibleSpace, connection, database, .flexibleSpace,
        MainWindowToolbar.refresh, MainWindowToolbar.actions,
    ]

    /// A toolbar restored with `placed`, on an identifier that never autosaves: the test host shares the
    /// app's defaults, so a toolbar named like the app's own would carry the edit into the next launch.
    private static func restoredToolbar(
        _ placed: [NSToolbarItem.Identifier] = defaultArrangement,
        identifier: String = "com.TablePro.tests.locationItems.\(UUID().uuidString)",
        settingOn: Bool,
        record: ToolbarLocationItemsRecord
    ) -> MainWindowToolbar {
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.autosavesConfiguration = false
        let owner = MainWindowToolbar(managedToolbar: toolbar)
        owner.isInWindow = { true }
        owner.locationItemsRecord = record
        owner.locationItemsEnabled = { settingOn }
        for identifier in placed {
            toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
        }
        return owner
    }

    private static func identifiers(of owner: MainWindowToolbar) -> [NSToolbarItem.Identifier] {
        owner.managedToolbar.items.map { $0.itemIdentifier }
    }

    private static func holdsThePair(_ owner: MainWindowToolbar) -> Bool {
        let placed = identifiers(of: owner)
        return placed.contains(connection) || placed.contains(database)
    }

    // MARK: - Off and on

    @Test("Turning the setting off takes the connection and database out, once")
    func turningOffRemovesThePairOnce() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLocationItemsRecord(defaults: storage.defaults)
        let owner = Self.restoredToolbar(settingOn: false, record: record)

        owner.reconcileLocationItems()

        #expect(!Self.holdsThePair(owner))
        #expect(Self.identifiers(of: owner) == [
            .toggleSidebar, .flexibleSpace, .flexibleSpace, MainWindowToolbar.refresh, MainWindowToolbar.actions,
        ])
        #expect(record.isApplied)

        let later = Self.restoredToolbar(settingOn: false, record: record)
        later.reconcileLocationItems()
        #expect(Self.holdsThePair(later), "The change was already written into the arrangement")
    }

    @Test("Turning it back on puts the pair back where it centres, after the first flexible space")
    func turningOnRestoresThePair() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLocationItemsRecord(defaults: storage.defaults)
        record.record(true)
        let owner = Self.restoredToolbar(
            [.toggleSidebar, .flexibleSpace, .flexibleSpace, MainWindowToolbar.refresh, MainWindowToolbar.actions],
            settingOn: true,
            record: record
        )

        owner.reconcileLocationItems()

        #expect(Self.identifiers(of: owner) == Self.defaultArrangement)
        #expect(!record.isApplied)
    }

    @Test("With the setting on and never turned off, an arrangement is left as it was and nothing is written")
    func settingOnLeavesTheArrangementAlone() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLocationItemsRecord(defaults: storage.defaults)
        let owner = Self.restoredToolbar([.toggleSidebar, Self.database, .flexibleSpace], settingOn: true, record: record)
        let before = Self.identifiers(of: owner)

        owner.reconcileLocationItems()

        #expect(Self.identifiers(of: owner) == before, "A pair the user changed by hand stays as they left it")
        #expect(storage.defaults.object(forKey: ToolbarLocationItemsRecord.key) == nil)
    }

    /// A customized arrangement may hold one of the pair, or none, and AppKit throws on a second item with
    /// an identifier the toolbar already holds.
    @Test("Turning it on adds only the missing half, beside the other")
    func turningOnAddsOnlyTheMissingHalf() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLocationItemsRecord(defaults: storage.defaults)
        record.record(true)
        let owner = Self.restoredToolbar(
            [.toggleSidebar, .flexibleSpace, Self.database, .flexibleSpace, MainWindowToolbar.refresh],
            settingOn: true,
            record: record
        )

        owner.reconcileLocationItems()

        #expect(Self.identifiers(of: owner) == [
            .toggleSidebar, .flexibleSpace, Self.connection, Self.database, .flexibleSpace, MainWindowToolbar.refresh,
        ])
    }

    @Test("A customized toolbar without either flexible space still takes the pair, ahead of Refresh")
    func customizedToolbarTakesThePair() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLocationItemsRecord(defaults: storage.defaults)
        let owner = Self.restoredToolbar(
            [.toggleSidebar, Self.connection, MainWindowToolbar.history, Self.database, MainWindowToolbar.refresh],
            settingOn: false,
            record: record
        )

        owner.reconcileLocationItems()
        #expect(Self.identifiers(of: owner) == [.toggleSidebar, MainWindowToolbar.history, MainWindowToolbar.refresh])

        owner.locationItemsEnabled = { true }
        owner.reconcileLocationItems()
        #expect(Self.identifiers(of: owner) == [
            .toggleSidebar, MainWindowToolbar.history, Self.connection, Self.database, MainWindowToolbar.refresh,
        ])
    }

    @Test("Where each half goes back, in every arrangement")
    func insertionIndex() {
        let index = MainWindowToolbar.locationInsertionIndex
        #expect(index(Self.connection, [.toggleSidebar, .flexibleSpace, Self.database]) == 2)
        #expect(index(Self.database, [.toggleSidebar, .flexibleSpace, Self.connection, .flexibleSpace]) == 3)
        #expect(index(Self.connection, [.toggleSidebar, .sidebarTrackingSeparator, MainWindowToolbar.objectTables,
                                        .flexibleSpace, .flexibleSpace]) == 4)
        #expect(index(Self.connection, [.flexibleSpace, .sidebarTrackingSeparator, MainWindowToolbar.refresh]) == 2)
        #expect(index(Self.connection, [.toggleSidebar, MainWindowToolbar.actions]) == 2)
    }

    @Test("A toolbar outside a window leaves the change for the next one")
    func noWindowLeavesTheChangeForTheNextOne() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLocationItemsRecord(defaults: storage.defaults)
        let owner = Self.restoredToolbar(settingOn: false, record: record)
        owner.isInWindow = { false }

        owner.reconcileLocationItems()
        #expect(Self.holdsThePair(owner))
        #expect(!record.isApplied)
    }

    // MARK: - What the delegate offers

    /// Toolbars sharing the identifier replay a removal or an insertion by index, so every member has to
    /// accept the pair whatever the setting says, and Customize Toolbar can still put it back.
    @Test("Off, the default set loses the pair while the delegate still allows and builds it")
    func offKeepsThePairAllowed() throws {
        let storage = try EphemeralDefaults()
        let owner = Self.restoredToolbar([], settingOn: false, record: ToolbarLocationItemsRecord(defaults: storage.defaults))
        let defaults = owner.toolbarDefaultItemIdentifiers(owner.managedToolbar)
        let allowed = owner.toolbarAllowedItemIdentifiers(owner.managedToolbar)

        #expect(!defaults.contains(Self.connection))
        #expect(!defaults.contains(Self.database))
        let spaces = { (identifiers: [NSToolbarItem.Identifier]) in identifiers.filter { $0 == .flexibleSpace }.count }
        #expect(
            spaces(defaults) == spaces(MainWindowToolbar.defaultItemIdentifiers),
            "The spaces that centred the pair stay"
        )
        #expect(allowed.contains(Self.connection))
        #expect(allowed.contains(Self.database))
        for identifier in [Self.connection, Self.database] {
            let built = owner.toolbar(owner.managedToolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true)
            #expect(built != nil, "\(identifier.rawValue) must still be built")
        }

        owner.locationItemsEnabled = { true }
        #expect(owner.toolbarDefaultItemIdentifiers(owner.managedToolbar) == MainWindowToolbar.defaultItemIdentifiers)
    }

    // MARK: - Toolbars sharing an identifier

    /// Every connection window's toolbar shares one identifier, and AppKit copies an edit made to one into
    /// the others by index. Whatever reaches each window first, the arrangements have to stay identical,
    /// or a later removal by index faults.
    @Test("Two windows sharing a toolbar identifier stay in step through off and on")
    func sharedIdentifierStaysInStep() throws {
        let storage = try EphemeralDefaults()
        let identifier = "com.TablePro.tests.locationItems.family.\(UUID().uuidString)"
        let setting = SettingBox()
        func make() -> (MainWindowToolbar, NSWindow) {
            let owner = Self.restoredToolbar(
                identifier: identifier, settingOn: true, record: ToolbarLocationItemsRecord(defaults: storage.defaults)
            )
            owner.locationItemsEnabled = { setting.isOn }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.toolbar = owner.managedToolbar
            return (owner, window)
        }
        let (first, firstWindow) = make()
        let (second, secondWindow) = make()
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }
        // A toolbar reaching its window takes the delegate's default set, which holds the pair while it is on.
        let original = Self.identifiers(of: first)
        #expect(Self.holdsThePair(first))

        setting.isOn = false
        for owner in [first, second] {
            owner.reconcileLocationItems()
        }
        #expect(!Self.holdsThePair(first))
        #expect(!Self.holdsThePair(second))
        #expect(Self.identifiers(of: first) == Self.identifiers(of: second))

        setting.isOn = true
        for owner in [second, first] {
            owner.reconcileLocationItems()
        }
        #expect(Self.identifiers(of: first) == original, "The pair is back where it was")
        #expect(Self.identifiers(of: second) == Self.identifiers(of: first))

        first.managedToolbar.removeItem(at: Self.identifiers(of: first).count - 1)
        #expect(Self.identifiers(of: second) == Self.identifiers(of: first), "A later edit by index still lands")
    }
}

@MainActor
private final class SettingBox {
    var isOn = true
}

extension GlobalStateSuites {
    /// The setting flipped the way Settings flips it, reaching connection windows that are already open.
    @MainActor
    struct ToolbarLocationItemsSettingTests {
        @Test(
            "The General setting takes the pair out of every open window and puts it back",
            .appSettings { $0.general.showsToolbarLocationItems = true }
        )
        func settingReachesEveryOpenWindow() throws {
            let windows = try (0 ..< 2).map { _ in try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861)) }
            defer { windows.forEach { $0.tearDown() } }
            var storages: [EphemeralDefaults] = []
            for fixture in windows {
                let storage = try EphemeralDefaults()
                storages.append(storage)
                fixture.toolbarOwner.locationItemsRecord = ToolbarLocationItemsRecord(defaults: storage.defaults)
            }
            let pair = Set(MainWindowToolbar.locationItemIdentifiers)
            func pairs() throws -> [[NSToolbarItem.Identifier]] {
                try windows.map { fixture in
                    try #require(fixture.window.toolbar).items.map { $0.itemIdentifier }.filter { pair.contains($0) }
                }
            }
            #expect(try pairs() == [MainWindowToolbar.locationItemIdentifiers, MainWindowToolbar.locationItemIdentifiers])

            AppSettingsManager.shared.general.showsToolbarLocationItems = false
            #expect(try pairs() == [[], []], "Turning the setting off reaches both open windows")

            AppSettingsManager.shared.general.showsToolbarLocationItems = true
            #expect(try pairs() == [MainWindowToolbar.locationItemIdentifiers, MainWindowToolbar.locationItemIdentifiers])
            for fixture in windows {
                let identifiers = try #require(fixture.window.toolbar).items.map { $0.itemIdentifier }
                let connection = try #require(identifiers.firstIndex(of: MainWindowToolbar.connection))
                #expect(identifiers[connection - 1] == .flexibleSpace, "The pair is centred again")
                #expect(identifiers[connection + 2] == .flexibleSpace)
            }
            withExtendedLifetime(storages) {}
        }

        /// The switchers anchor on the capsules when they are in the toolbar and fall back to the floating
        /// panel when not, so the Database menu keeps working with the pair taken out.
        @Test(
            "With the pair out, the switchers find no anchor and take the floating panel",
            .appSettings { $0.general.showsToolbarLocationItems = true }
        )
        func switchersFallBackWithoutThePair() throws {
            let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861))
            defer { fixture.tearDown() }
            let storage = try EphemeralDefaults()
            fixture.toolbarOwner.locationItemsRecord = ToolbarLocationItemsRecord(defaults: storage.defaults)
            let visibility = ToolbarVisibility()

            #expect(ToolbarSwitcherPresenter.anchor(in: fixture.window, MainWindowToolbar.connection, hiddenBy: visibility) != nil)

            AppSettingsManager.shared.general.showsToolbarLocationItems = false

            #expect(ToolbarSwitcherPresenter.anchor(in: fixture.window, MainWindowToolbar.connection, hiddenBy: visibility) == nil)
            #expect(ToolbarSwitcherPresenter.anchor(in: fixture.window, MainWindowToolbar.database, hiddenBy: visibility) == nil)
        }
    }
}
