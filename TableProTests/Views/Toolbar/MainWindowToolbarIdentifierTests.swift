//
//  MainWindowToolbarIdentifierTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// From the macOS 15 SDK, "an exception will be thrown if a new item is added to the toolbar when
/// an item with that identifier already exists", space items excepted. Every main window shares one
/// toolbar identifier and autosaves its configuration, so a repeated identifier is a launch crash
/// rather than a duplicated button.
@MainActor
@Suite("Main window toolbar identifiers")
struct MainWindowToolbarIdentifierTests {
    @Test("No identifier is listed twice in the default set")
    func defaultIdentifiersAreUnique() {
        expectNoDuplicates(in: MainWindowToolbar.defaultItemIdentifiers, list: "default")
    }

    @Test("No identifier is listed twice in the allowed set")
    func allowedIdentifiersAreUnique() {
        expectNoDuplicates(in: MainWindowToolbar.allowedItemIdentifiers, list: "allowed")
    }

    @Test("Every default item is also allowed, so customization cannot drop one")
    func defaultsAreAllowed() {
        let allowed = Set(MainWindowToolbar.allowedItemIdentifiers)
        let missing = MainWindowToolbar.defaultItemIdentifiers.filter { !allowed.contains($0) }

        #expect(missing.isEmpty, "Default items missing from the allowed set: \(missing.map(\.rawValue))")
    }

    /// The palette's tail is where the commands that left the default set went, so the two lists
    /// being equal would mean a user could no longer put any of them back.
    @Test("The allowed set offers more than the default set")
    func allowedIsAProperSuperset() {
        let allowed = Set(MainWindowToolbar.allowedItemIdentifiers)
        let defaults = Set(MainWindowToolbar.defaultItemIdentifiers)
        #expect(defaults.isStrictSubset(of: allowed))
    }

    /// The named test for the hideability rule. An identifier is hideable exactly when the app puts
    /// it in the toolbar itself, so a context can never take out an item the user dragged in, and a
    /// change that adds to the hidden set without adding to the default list, or collapses the two
    /// lists into one, fails here.
    @Test("Hideable is exactly the default set")
    func hideableIsExactlyTheDefaultSet() {
        #expect(ToolbarContextResolver.hideableIdentifiers == Set(MainWindowToolbar.defaultItemIdentifiers))

        let paletteOnly = Set(MainWindowToolbar.allowedItemIdentifiers)
            .subtracting(MainWindowToolbar.defaultItemIdentifiers)
        #expect(ToolbarContextResolver.hideableIdentifiers.isDisjoint(with: paletteOnly))
    }

    /// The autosave name. Measured on macOS 27, AppKit splices a new default identifier into a
    /// saved arrangement at its default position and prunes one the delegate stops vending, so the
    /// default set can change without discarding anyone's arrangement. A bump discards it, along
    /// with the display mode they chose, so it has to be a decision with a reason rather than a
    /// reflex; this is where that decision is made visible.
    @Test("The toolbar identifier stays at v4")
    func toolbarIdentifierIsPinned() {
        #expect(MainWindowToolbar.toolbarIdentifier == "com.TablePro.main.toolbar.v4")
    }

    /// AppKit asks the delegate for every allowed identifier to fill the palette, and with
    /// `autosavesConfiguration` on an identifier the delegate answers nil for is pruned from the
    /// saved arrangement. The standard identifiers are built by AppKit itself and never asked for.
    @Test("The delegate builds every allowed identifier it owns")
    func everyAllowedIdentifierIsVendable() {
        let owner = MainWindowToolbar()
        let owned = MainWindowToolbar.allowedItemIdentifiers.filter { !$0.rawValue.hasPrefix("NSToolbar") }

        #expect(!owned.isEmpty)
        for identifier in owned {
            let item = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: false
            )
            #expect(item?.itemIdentifier == identifier, "\(identifier.rawValue) must build from the palette")
        }
    }

    private func expectNoDuplicates(in identifiers: [NSToolbarItem.Identifier], list: String) {
        let spaces: Set<NSToolbarItem.Identifier> = [.space, .flexibleSpace]
        var seen: Set<NSToolbarItem.Identifier> = []
        var duplicates: [String] = []

        for identifier in identifiers where !spaces.contains(identifier) {
            if !seen.insert(identifier).inserted {
                duplicates.append(identifier.rawValue)
            }
        }

        #expect(
            duplicates.isEmpty,
            """
            The \(list) identifier list repeats \(duplicates.sorted()). AppKit throws when a second \
            item with the same identifier is added, and this toolbar is built on every window.
            """
        )
    }
}
