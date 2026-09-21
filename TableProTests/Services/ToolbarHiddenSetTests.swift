//
//  ToolbarHiddenSetTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
private final class CountingToolbar: NSToolbar {
    private(set) var validationCount = 0

    override func validateVisibleItems() {
        validationCount += 1
    }
}

/// The context is written onto a live toolbar through `isHidden`, onto the items the app placed and
/// onto nothing else. These run against a real `NSToolbar`, because the rules they pin are about
/// what AppKit does with the writes, which no pure test can see.
@Suite("Toolbar hidden set")
@MainActor
struct ToolbarHiddenSetTests {
    /// The app's own items in the order the default set gives them, without the spaces and tracking
    /// separators, which need a window's split view to mean anything.
    private static let placed: [NSToolbarItem.Identifier] = [
        MainWindowToolbar.connection,
        MainWindowToolbar.database,
        MainWindowToolbar.refresh,
        MainWindowToolbar.saveChanges,
        MainWindowToolbar.actions,
        MainWindowToolbar.safeMode,
    ]

    /// A private identifier with autosave off, so no arrangement written here reaches the app's own
    /// defaults, which the test host shares.
    private func makeOwner() -> (owner: MainWindowToolbar, toolbar: CountingToolbar) {
        let toolbar = CountingToolbar(identifier: "com.TablePro.tests.hidden.\(UUID().uuidString)")
        let owner = MainWindowToolbar(managedToolbar: toolbar)
        toolbar.autosavesConfiguration = false
        for (index, identifier) in Self.placed.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        return (owner, toolbar)
    }

    private func item(_ identifier: NSToolbarItem.Identifier, in toolbar: NSToolbar) -> NSToolbarItem? {
        toolbar.items.first { $0.itemIdentifier == identifier }
    }

    /// Lets what a case's setup asked for arrive before the case starts counting: the pass the
    /// toolbar's own inserts asked for, and the observer callbacks a repoint queued.
    ///
    /// Wall-clock time, not main-actor hops. Measured in the test host, an insert's announcement
    /// reaches the delegate only once the run loop turns, and five main-actor hops after building
    /// the toolbar had not yet run the pass its six inserts asked for.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// Waits until the condition holds, bounded at two seconds. A sleep hands the main thread back
    /// to the run loop, which is what delivers both an insert's announcement and every observer
    /// that receives on `RunLoop.main`. A chain of main-actor hops can drain inside one pass of the
    /// main queue without the run loop ever turning, and a spun run loop runs no main-actor job at
    /// all, because the test is itself one.
    private func waitForRunLoop(until condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db_a"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    @available(macOS 15.0, *)
    @Test("Applying a context hides exactly its set and validates once")
    func applyWritesTheResolversSet() throws {
        let (owner, toolbar) = makeOwner()
        let context = ToolbarContext(tabKind: .erDiagram, isFileBased: true, supportsContainerSwitching: false)
        let visibility = ToolbarContextResolver.visibility(for: context.visibilityKey)
        #expect(visibility.hidden == [MainWindowToolbar.database, MainWindowToolbar.saveChanges])

        let baseline = toolbar.validationCount
        owner.apply(visibility)

        #expect(toolbar.validationCount == baseline + 1)
        #expect(owner.visibility == visibility)
        for identifier in Self.placed {
            let placedItem = try #require(item(identifier, in: toolbar))
            #expect(placedItem.isHidden == visibility.hides(identifier), "\(identifier.rawValue)")
        }
    }

    /// Measured on macOS 27 with a palette item dragged between two of the app's own: 200 passes
    /// that hid the items around it left it at its index, visible, with its frame unchanged. The
    /// filter lives in the loop, so it holds even for a record that names the user's item.
    @available(macOS 15.0, *)
    @Test("An item added from the palette keeps its place and stays visible through a pass")
    func paletteItemSurvivesAPass() throws {
        let (owner, toolbar) = makeOwner()
        toolbar.insertItem(withItemIdentifier: MainWindowToolbar.previewSQL, at: 3)
        let before = toolbar.items.map(\.itemIdentifier)

        owner.apply(ToolbarVisibility(hidden: [MainWindowToolbar.previewSQL, MainWindowToolbar.saveChanges]))

        let preview = try #require(item(MainWindowToolbar.previewSQL, in: toolbar))
        #expect(preview.isHidden == false)
        #expect(toolbar.items.map(\.itemIdentifier) == before)
        #expect(toolbar.items.firstIndex { $0.itemIdentifier == MainWindowToolbar.previewSQL } == 3)
        #expect(item(MainWindowToolbar.saveChanges, in: toolbar)?.isHidden == true)
    }

    /// Never written, not merely written false: an item that arrived hidden from anywhere else
    /// keeps whatever it had, because a pass has no business with an item the app did not place.
    @available(macOS 15.0, *)
    @Test("A pass leaves an item the user added untouched")
    func paletteItemIsNeverWritten() throws {
        let (owner, toolbar) = makeOwner()
        toolbar.insertItem(withItemIdentifier: MainWindowToolbar.history, at: 2)
        let history = try #require(item(MainWindowToolbar.history, in: toolbar))
        history.isHidden = true

        owner.apply(ToolbarVisibility())

        #expect(history.isHidden == true)
        #expect(item(MainWindowToolbar.database, in: toolbar)?.isHidden == false)
    }

    /// Measured on macOS 27: with an instance cached across vends, an item the user dragged back in
    /// from the palette was that same instance, arrived with `isHidden` still true, took its slot
    /// and drew nothing.
    @Test("Every hideable item is built fresh on each vend")
    func hideableItemsAreNeverCached() {
        let owner = MainWindowToolbar()
        let owned = ToolbarContextResolver.hideableIdentifiers.filter { !$0.rawValue.hasPrefix("NSToolbar") }

        #expect(!owned.isEmpty)
        for identifier in owned {
            let vends = [true, false].map { flag in
                owner.toolbar(owner.managedToolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag)
            }
            /// Both, before the identity comparison: a second vend of nil is also "not the same
            /// instance", and would pass a delegate that stopped building the item at all.
            guard let first = vends[0], let second = vends[1] else {
                Issue.record("\(identifier.rawValue) vended nil: \(vends.map { $0 == nil })")
                continue
            }
            #expect(first !== second, "\(identifier.rawValue) handed back a cached instance")
        }
    }

    /// The item a drop announces is not in `NSToolbar.items` until the announcement returns, so the
    /// pass that picks it up runs on a later turn. Until then the fresh item shows, which is the
    /// safe direction to be wrong in for a moment.
    @available(macOS 15.0, *)
    @Test("An item put back from the palette takes the context on the next turn")
    func droppedItemTakesTheContextNextTurn() async throws {
        let (owner, toolbar) = makeOwner()
        await settle()
        owner.apply(ToolbarVisibility(hidden: [MainWindowToolbar.refresh]))
        let index = try #require(toolbar.items.firstIndex { $0.itemIdentifier == MainWindowToolbar.refresh })
        toolbar.removeItem(at: index)

        toolbar.insertItem(withItemIdentifier: MainWindowToolbar.refresh, at: index)
        let dropped = try #require(item(MainWindowToolbar.refresh, in: toolbar))
        #expect(dropped.isHidden == false, "A fresh item arrives visible, and the pass is not run in the notification")

        #expect(await waitForRunLoop { dropped.isHidden })
    }

    /// A Customize Toolbar drop of several items announces each one, and each announcement asks for
    /// a pass. They coalesce into one, because every pass validates every visible item.
    ///
    /// The pass the toolbar's own inserts asked for is let through first, and the count is read
    /// again after a quiet interval rather than the moment it first moves, so a second pass that
    /// arrived late would still be counted.
    ///
    /// Every wait reads `NSToolbar.items`. Measured in the test host, a toolbar with no window
    /// announces an insert to its delegate only once its items are next read: a wait on the pass
    /// count alone saw no pass for two seconds, and the pass followed the first read of the items.
    /// A window reads them on its next layout, so in the app the pass follows the drop; here the
    /// waits stand in for that layout.
    @available(macOS 15.0, *)
    @Test("Two items put back in one turn cost exactly one pass")
    func aBurstOfDropsIsOnePass() async throws {
        let (owner, toolbar) = makeOwner()
        #expect(
            await waitForRunLoop { toolbar.items.count == Self.placed.count && toolbar.validationCount > 0 },
            "Building the toolbar asked for no pass"
        )
        await settle()
        owner.apply(ToolbarVisibility(hidden: [MainWindowToolbar.refresh, MainWindowToolbar.saveChanges]))
        for identifier in [MainWindowToolbar.saveChanges, MainWindowToolbar.refresh] {
            let index = try #require(toolbar.items.firstIndex { $0.itemIdentifier == identifier })
            toolbar.removeItem(at: index)
        }
        await settle()

        let beforeDrops = toolbar.validationCount
        toolbar.insertItem(withItemIdentifier: MainWindowToolbar.refresh, at: 2)
        toolbar.insertItem(withItemIdentifier: MainWindowToolbar.saveChanges, at: 3)
        let afterDrops = toolbar.validationCount
        #expect(afterDrops == beforeDrops, "The pass must not run inside the announcement")

        #expect(
            await waitForRunLoop { toolbar.items.count == Self.placed.count && toolbar.validationCount > afterDrops },
            "No pass ran for the drops at all"
        )
        await settle()
        #expect(toolbar.validationCount == afterDrops + 1)
        #expect(item(MainWindowToolbar.refresh, in: toolbar)?.isHidden == true)
        #expect(item(MainWindowToolbar.saveChanges, in: toolbar)?.isHidden == true)
    }

    // MARK: - The commit verb on a live item

    /// A Create Table draft raises and drops its staged change as it becomes valid and invalid, so a
    /// label that followed it flipped while the user typed and, with labels shown, reflowed the
    /// titlebar. The observer running is proven by the pass it asks for, so the unchanged label is
    /// not the absence of a callback.
    @Test("Staging a change under a live commit control leaves its label alone")
    func stagingLeavesTheLabelAlone() async throws {
        let (owner, toolbar) = makeOwner()
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab()
        owner.repoint(to: coordinator)
        await settle()
        let commit = try #require(item(MainWindowToolbar.saveChanges, in: toolbar))
        #expect(commit.label == String(localized: "Save Changes"))

        for staged in [PendingChangeKind.createTable, .principals, nil] {
            let before = toolbar.validationCount
            coordinator.toolbarState.pendingChange = staged
            #expect(
                await waitForRunLoop { toolbar.validationCount > before },
                "The toolbar-state observer never ran, so the label check below proves nothing"
            )
            #expect(commit.label == String(localized: "Save Changes"), "\(String(describing: staged))")
            #expect(commit.menuFormRepresentation?.title == String(localized: "Save Changes"))
        }
    }

    /// The verb is the tab's, so it moves when the tab does, on the same observer that moves the
    /// item set, and reaches the overflow entry as well as the label.
    @Test("Switching to another kind of tab relabels the live commit control")
    func tabSwitchRelabelsTheCommitControl() async throws {
        let (owner, toolbar) = makeOwner()
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab()
        owner.repoint(to: coordinator)
        let commit = try #require(item(MainWindowToolbar.saveChanges, in: toolbar))
        #expect(commit.label == String(localized: "Save Changes"))

        coordinator.tabManager.addCreateTableTab()
        #expect(await waitForRunLoop { commit.label == String(localized: "Create Table") })
        #expect(commit.menuFormRepresentation?.title == String(localized: "Create Table"))

        coordinator.tabManager.selectTab(at: 0)
        #expect(await waitForRunLoop { commit.label == String(localized: "Save Changes") })
    }
}
