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
    /// Items ahead of `.sidebarTrackingSeparator` lay out in the sidebar's own titlebar strip and
    /// follow its divider. The sidebar toggle is the only thing that belongs there: the list chooser
    /// that used to share the strip now sits at the top of the sidebar, over the list it switches.
    @Test("AppKit's sidebar toggle is alone in the sidebar's titlebar strip")
    func sidebarToggleIsAloneBeforeTheTrackingSeparator() throws {
        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let separatorIndex = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        #expect(Array(identifiers[..<separatorIndex]) == [.toggleSidebar])
    }

    /// `.toggleSidebar` is a standard identifier, so AppKit builds it, labels it, gives it a menu
    /// form and sends `toggleSidebar:` down the responder chain, where the window answers for it in
    /// every phase. A delegate arm for it could only be worse.
    @Test("The sidebar toggle is AppKit's own item")
    func sidebarToggleIsTheStandardItem() {
        let owner = MainWindowToolbar()
        let item = owner.toolbar(
            owner.managedToolbar,
            itemForItemIdentifier: .toggleSidebar,
            willBeInsertedIntoToolbar: true
        )
        #expect(item == nil)
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

    /// One flexible space, immediately after the separator, is what pushes the toggle to the window
    /// edge. The trailing-pane toggle is the only control behind it: the assistant is a surface of
    /// the same pane, and a second button there drove the same column under another name.
    @available(macOS 14.0, *)
    @Test("A flexible space anchors the trailing toggle to the window edge")
    func flexibleSpaceSeparatesTheTrackingSeparatorFromTheToggle() throws {
        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let separatorIndex = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        let toggleIndex = try #require(identifiers.firstIndex(of: MainWindowToolbar.inspector))
        #expect(separatorIndex < toggleIndex)
        let trailingRun: [NSToolbarItem.Identifier] = [
            .inspectorTrackingSeparator, .flexibleSpace, MainWindowToolbar.inspector,
        ]
        #expect(Array(identifiers[separatorIndex...]) == trailingRun)
    }

    /// The assistant left the default set with the trailing run's second button, and stays one drag
    /// away in Customize Toolbar for a user who wants a button that goes straight to it.
    /// The assistant has no toolbar item at all any more, in either list.
    ///
    /// One command, one control: the trailing-pane toggle says whether the pane is open and the
    /// picker in the pane's header says which surface it draws. A second button that did both at
    /// once was the shape this revamp took the Tables and Favorites control out of the titlebar
    /// for, and offering it in Customize Toolbar kept it reachable. View > Show Assistant and
    /// ⌥⌘A are the command, and `TrailingPaneCommandTitleTests` is what pins their behaviour.
    @Test("No toolbar item opens the assistant")
    func assistantHasNoToolbarItem() {
        let identifiers = Set(MainWindowToolbar.allowedItemIdentifiers).union(
            MainWindowToolbar.defaultItemIdentifiers
        )
        #expect(!identifiers.contains { $0.rawValue.hasSuffix(".assistant") })
    }

    /// Ahead of the separator the toggle lands in the content section, which measured wrong in both
    /// the open and the closed state.
    @available(macOS 14.0, *)
    @Test("The inspector toggle stays behind its tracking separator")
    func toggleNeverPrecedesItsTrackingSeparator() throws {
        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let separatorIndex = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        #expect(!identifiers[..<separatorIndex].contains(MainWindowToolbar.inspector))
    }

    @available(macOS 14.0, *)
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
        #expect(standard.contains(.toggleSidebar))
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
            #selector(MainWindowToolbar.performSaveChanges(_:)): MainWindowToolbar.saveChanges,
            #selector(MainWindowToolbar.performNewTab(_:)): MainWindowToolbar.newTab,
            #selector(MainWindowToolbar.performOpenQuickSwitcher(_:)): MainWindowToolbar.quickSwitcher,
            #selector(MainWindowToolbar.performExport(_:)): MainWindowToolbar.exportTables,
            #selector(MainWindowToolbar.performOpenDatabaseSwitcher(_:)): MainWindowToolbar.database,
            #selector(MainWindowToolbar.performToggleResults(_:)): MainWindowToolbar.results,
            #selector(MainWindowToolbar.performShowDashboard(_:)): MainWindowToolbar.dashboard,
            #selector(MainWindowToolbar.performAddRow(_:)): MainWindowToolbar.addRow,
            #selector(MainWindowToolbar.performRestorePreviousValues(_:)): MainWindowToolbar.restorePreviousValues,
        ]

        for (action, identifier) in expected {
            #expect(
                owner.itemIdentifier(forMenuFormAction: action) == identifier,
                "\(NSStringFromSelector(action)) must validate as \(identifier.rawValue)"
            )
        }
    }

    /// The Import item carries no action of its own, and its format entries carry no target, so
    /// they reach the window's controller through the responder chain and are validated there. An
    /// entry targeted at the toolbar would be validated by `MainWindowToolbar.validateMenuItem`,
    /// which answers true for every action it did not build.
    @Test("The import formats resolve through the responder chain, never through the toolbar")
    func importFormatsResolveThroughTheResponderChain() {
        let owner = MainWindowToolbar()
        let item = owner.makeImportItem()
        let format = ImportFormatMenuDelegate.item(for: ImportFormatOption(id: "csv", name: "CSV"))

        #expect(item.action == nil)
        #expect(item.menuFormRepresentation?.submenu?.delegate === owner.importFormatMenuDelegate)
        #expect(format.target == nil)
        #expect(format.action == #selector(MainSplitViewController.importDataFormat(_:)))
        #expect(format.representedObject as? String == "csv")
        #expect(owner.itemIdentifier(forMenuFormAction: format.action) == nil)
        #expect(
            MainSplitViewController.resolvedEnablement(
                #selector(MainSplitViewController.importDataFormat(_:)),
                context: MenuValidationContext()
            ) == false
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
        _ = owner.makeRefreshItem()
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
