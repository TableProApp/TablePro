//
//  MainWindowToolbarLayoutTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct MainWindowToolbarLayoutTests {
    @Test("Sidebar toggle is ordered into the sidebar's titlebar strip")
    func sidebarToggleOrderedBeforeTrackingSeparator() throws {
        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let toggleIndex = try #require(identifiers.firstIndex(of: MainWindowToolbar.sidebarToggle))
        let separatorIndex = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        #expect(toggleIndex < separatorIndex)
    }

    @Test("Sidebar toggle is not navigational")
    func sidebarToggleIsNotNavigational() {
        let group = MainWindowToolbar.makeSidebarSegmentGroup(target: nil, action: #selector(NSView.layout))
        #expect(group.isNavigational == false)
    }

    @Test("Sidebar toggle stays an expanded one-of-two segmented control")
    func sidebarToggleIsExpandedSegmentedControl() {
        let group = MainWindowToolbar.makeSidebarSegmentGroup(target: nil, action: #selector(NSView.layout))
        #expect(group.controlRepresentation == .expanded)
        #expect(group.selectionMode == .selectOne)
        #expect(group.subitems.count == 2)
    }
}

/// A tracking separator divides the toolbar into pane-aligned sections and leaves the items inside
/// one leading-aligned, so the toggle rode the inspector divider inward as the pane opened and only
/// looked right while the inspector was closed. Measured on macOS 27 in a 1400pt window with a
/// 270pt inspector: the toggle sat at x=1135 open and x=1352 closed, and the flexible space holds
/// it at x=1352 in both. This suite pins the order Apple ships in WWDC23 session 10054.
@MainActor
struct MainWindowToolbarInspectorPlacementTests {
    @Test("The inspector toggle is the trailing-most item")
    func inspectorToggleIsTrailingMost() {
        #expect(MainWindowToolbar.defaultItemIdentifiers.last == MainWindowToolbar.inspector)
    }

    @Test("A flexible space anchors the inspector toggle to the window edge")
    func flexibleSpaceSeparatesTheTrackingSeparatorFromTheToggle() throws {
        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let separatorIndex = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        let toggleIndex = try #require(identifiers.firstIndex(of: MainWindowToolbar.inspector))
        #expect(separatorIndex < toggleIndex)
        #expect(Array(identifiers[(separatorIndex + 1) ..< toggleIndex]) == [.flexibleSpace])
    }

    /// Ahead of the separator the toggle lands in the content section, which measured wrong in both
    /// the open and the closed state.
    @Test("The inspector toggle stays behind its tracking separator")
    func toggleNeverPrecedesItsTrackingSeparator() throws {
        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let separatorIndex = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        #expect(!identifiers[..<separatorIndex].contains(MainWindowToolbar.inspector))
    }

    @Test("The inspector item is AppKit's standard toggle, not a private identifier")
    func inspectorIsTheStandardIdentifier() {
        #expect(MainWindowToolbar.inspector == NSToolbarItem.Identifier.toggleInspector)
    }

    /// `NSToolbarItem.h`: AppKit creates the standard identifiers itself and "the delegate method
    /// will not be called for these items". A delegate arm for one is dead code that can only ever
    /// be worse than the item AppKit builds, which already carries the label, the state-aware
    /// tooltip, the `toggleInspector:` action and a menu form.
    @Test("The delegate builds none of AppKit's standard items")
    func delegateDoesNotAnswerForStandardIdentifiers() {
        let owner = MainWindowToolbar()
        let standard = MainWindowToolbar.allowedItemIdentifiers.filter { $0.rawValue.hasPrefix("NSToolbar") }

        #expect(standard.contains(MainWindowToolbar.inspector))
        for identifier in standard {
            let item = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
            #expect(item == nil, "\(identifier.rawValue) must be left to AppKit")
        }
    }
}

/// AppKit validates an overflowed toolbar item as a menu item, so `validateToolbarItem(_:)` never
/// runs for it. Every action therefore has to resolve back to the identifier whose predicate gates
/// it, or the overflow entry stays enabled while the same button is disabled.
@MainActor
struct MainWindowToolbarOverflowValidationTests {
    private func vendedItems() -> (MainWindowToolbar, [NSToolbarItem]) {
        let owner = MainWindowToolbar()
        let items = MainWindowToolbar.allowedItemIdentifiers
            .compactMap {
                owner.toolbar(owner.managedToolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: true)
            }
            .flatMap { item -> [NSToolbarItem] in
                guard let group = item as? NSToolbarItemGroup else { return [item] }
                return [item] + group.subitems
            }
        return (owner, items)
    }

    /// Scoped to the items this toolbar targets, because those are exactly the ones AppKit routes
    /// back to `validateMenuItem(_:)`. A menu entry AppKit synthesizes with a selector of its own
    /// is not ours to answer for, and whether it exists at all depends on when AppKit builds it.
    @Test("Every action the toolbar owns resolves to the item it stands for")
    func everyOwnedActionResolvesToAnIdentifier() {
        let (owner, items) = vendedItems()
        let owned = items.filter { $0.target === owner }.compactMap(\.action)

        #expect(!owned.isEmpty)
        for action in owned {
            #expect(
                owner.itemIdentifier(forMenuFormAction: action) != nil,
                "\(NSStringFromSelector(action)) has no toolbar item to validate against"
            )
        }
    }

    /// The gap this closed: seven of the twelve actions had no entry, so their overflow entries
    /// stayed enabled with no session while the same buttons were disabled.
    @Test("Connection-scoped actions all reach the session predicate")
    func connectionScopedActionsAreAllMapped() {
        let (owner, _) = vendedItems()
        let expected: [Selector: NSToolbarItem.Identifier] = [
            #selector(MainWindowToolbar.performRefresh(_:)): MainWindowToolbar.refresh,
            #selector(MainWindowToolbar.performNewTab(_:)): MainWindowToolbar.newTab,
            #selector(MainWindowToolbar.performOpenQuickSwitcher(_:)): MainWindowToolbar.quickSwitcher,
            #selector(MainWindowToolbar.performExport(_:)): MainWindowToolbar.exportTables,
            #selector(MainWindowToolbar.performOpenDatabaseSwitcher(_:)): MainWindowToolbar.database,
            #selector(MainWindowToolbar.performToggleResults(_:)): MainWindowToolbar.results,
            #selector(MainWindowToolbar.performShowDashboard(_:)): MainWindowToolbar.dashboard,
        ]

        for (action, identifier) in expected {
            #expect(
                owner.itemIdentifier(forMenuFormAction: action) == identifier,
                "\(NSStringFromSelector(action)) must validate as \(identifier.rawValue)"
            )
        }
    }

    /// The import control carries no action of its own; its submenu entries do.
    @Test("The import submenu validates as the import item")
    func importSubmenuResolvesToTheImportItem() {
        let owner = MainWindowToolbar()
        _ = owner.subitemImport()
        #expect(
            owner.itemIdentifier(forMenuFormAction: #selector(MainWindowToolbar.performImportFormat(_:)))
                == MainWindowToolbar.importTables
        )
    }

    /// With no connection the toolbar disables these, so the overflow menu must too.
    @Test("A menu item with no session is disabled, not silently inert")
    func connectionScopedEntriesAreDisabledWithoutASession() {
        let owner = MainWindowToolbar()
        let menuItem = NSMenuItem(
            title: "Refresh",
            action: #selector(MainWindowToolbar.performRefresh(_:)),
            keyEquivalent: ""
        )
        _ = owner.subitemRefresh()
        #expect(!owner.validateMenuItem(menuItem))
    }

    /// A menu item this toolbar never built is not its to judge.
    @Test("An unrelated menu item is left alone")
    func unrelatedMenuItemsValidateTrue() {
        let owner = MainWindowToolbar()
        let menuItem = NSMenuItem(title: "Unrelated", action: #selector(NSView.layout), keyEquivalent: "")
        #expect(owner.validateMenuItem(menuItem))
    }
}

@MainActor
struct MainWindowToolbarCustomizationTests {
    /// Opening Customize Toolbar makes AppKit ask the delegate again, with the flag off, for the
    /// palette copies. Those used to overwrite the retained hosting controllers, releasing the ones
    /// whose views were on screen, and the connection group and status item collapsed to nothing.
    @Test("Only the item going into the toolbar claims the retained controller")
    func paletteCopiesDoNotClaimTheSlot() {
        #expect(MainWindowToolbar.claimsItemSlot(willBeInsertedIntoToolbar: true))
        #expect(!MainWindowToolbar.claimsItemSlot(willBeInsertedIntoToolbar: false))
    }

    /// The sidebar segmented control keeps a slot of the same shape, and it never read the guard.
    /// A palette copy took the slot, so every later `syncSidebarSelection()` wrote into a discarded
    /// group and the segments stopped following the sidebar until the window was reopened.
    @Test("A palette copy does not take over the live sidebar control")
    func paletteCopyDoesNotClaimTheSidebarGroup() throws {
        let owner = MainWindowToolbar()
        let live = try #require(owner.makeSidebarToggleItem(claimsSlot: true) as? NSToolbarItemGroup)
        #expect(owner.sidebarGroup === live)

        let palette = try #require(owner.makeSidebarToggleItem(claimsSlot: false) as? NSToolbarItemGroup)
        #expect(palette !== live)
        #expect(owner.sidebarGroup === live)
    }

    /// The delegate is the path Customize Toolbar actually takes.
    @Test("Vending a palette item through the delegate leaves the live control alone")
    func delegatePaletteVendLeavesTheSidebarGroupIntact() throws {
        let owner = MainWindowToolbar()
        _ = owner.toolbar(
            owner.managedToolbar,
            itemForItemIdentifier: MainWindowToolbar.sidebarToggle,
            willBeInsertedIntoToolbar: true
        )
        let live = try #require(owner.sidebarGroup)

        _ = owner.toolbar(
            owner.managedToolbar,
            itemForItemIdentifier: MainWindowToolbar.sidebarToggle,
            willBeInsertedIntoToolbar: false
        )
        #expect(owner.sidebarGroup === live)
    }

    /// The identifier is the autosave name. Changing it silently discards every user's arrangement,
    /// which is what the v1 to v2 move already cost once.
    @Test("The toolbar identifier is stable")
    func identifierIsStable() {
        #expect(MainWindowToolbar.toolbarIdentifier == "com.TablePro.main.toolbar.v2")
    }
}

@MainActor
struct MainWindowToolbarHostedSizingTests {
    private static let hostedIdentifiers: [NSToolbarItem.Identifier] = [
        MainWindowToolbar.connectionGroup,
        MainWindowToolbar.principal,
    ]

    private func vendHostedItems() -> MainWindowToolbar {
        let owner = MainWindowToolbar()
        for identifier in Self.hostedIdentifiers {
            _ = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
        }
        return owner
    }

    /// AppKit measures a view-backed item when it is inserted and never reads that size again, so
    /// the hosting view has to resize itself. Under `.intrinsicContentSize` it does not, and the
    /// leading group kept the width of the connection the window had switched away from until the
    /// user clicked the toolbar.
    @Test("Hosted toolbar items size themselves from the preferred content size")
    func hostedItemsSizeFromPreferredContentSize() throws {
        let owner = vendHostedItems()
        for identifier in Self.hostedIdentifiers {
            let controller = try #require(owner.hostingControllers[identifier])
            #expect(controller.sizingOptions == .preferredContentSize, "\(identifier.rawValue)")
        }
    }

    /// Measured on macOS 27: `[.minSize, .intrinsicContentSize, .maxSize]` shrinks the hosted
    /// content but leaves AppKit's item container at the old width, drawing the new content
    /// centred inside the old box. That is the artifact this suite exists to keep out.
    @Test("Hosted toolbar items never size from the intrinsic content size")
    func hostedItemsNeverSizeFromIntrinsicContentSize() throws {
        let owner = vendHostedItems()
        for identifier in Self.hostedIdentifiers {
            let controller = try #require(owner.hostingControllers[identifier])
            #expect(!controller.sizingOptions.contains(.intrinsicContentSize), "\(identifier.rawValue)")
        }
    }

    /// Both hosted items are built through the same two helpers, so the contract belongs to the
    /// helpers rather than to either call site.
    @Test("Every hosted item shares one sizing contract")
    func hostedItemsShareOneSizingContract() {
        #expect(MainWindowToolbar.hostedItemSizingOptions == .preferredContentSize)
    }
}
