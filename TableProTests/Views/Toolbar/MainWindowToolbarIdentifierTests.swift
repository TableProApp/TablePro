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
