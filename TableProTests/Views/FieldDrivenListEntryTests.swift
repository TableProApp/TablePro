//
//  FieldDrivenListEntryTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Field driven list entries")
struct FieldDrivenListEntryTests {
    private struct Item: Identifiable, Equatable {
        let id: String
    }

    private func section(_ id: String, title: String?, _ names: [String]) -> FieldDrivenListSection<Item> {
        FieldDrivenListSection(id: id, title: title, items: names.map(Item.init))
    }

    @Test("An untitled section contributes its rows and no header")
    func untitledSectionHasNoHeader() {
        let entries = FieldDrivenListEntry.flatten([section("a", title: nil, ["one", "two"])])
        #expect(entries.count == 2)
        #expect(entries.compactMap(\.itemId) == ["one", "two"])
        #expect(entries.filter(\.isHeader).isEmpty)
    }

    @Test("A titled section puts its header above its rows")
    func titledSectionLeadsWithHeader() {
        let entries = FieldDrivenListEntry.flatten([section("a", title: "ACTIVE", ["one"])])
        #expect(entries.count == 2)
        #expect(entries[0].isHeader)
        #expect(entries[0].itemId == nil)
        #expect(entries[1].itemId == "one")
    }

    /// A section that filters down to nothing must not leave its title behind.
    @Test("An empty section contributes nothing at all")
    func emptySectionIsDropped() {
        let entries = FieldDrivenListEntry.flatten([
            section("a", title: "ACTIVE", []),
            section("b", title: "SAVED", ["one"]),
        ])
        #expect(entries.count == 2)
        #expect(entries[0].isHeader)
        #expect(entries[1].itemId == "one")
    }

    @Test("Sections keep their order and their rows keep theirs")
    func orderIsPreserved() {
        let entries = FieldDrivenListEntry.flatten([
            section("a", title: "ACTIVE", ["one", "two"]),
            section("b", title: "SAVED", ["three"]),
        ])
        #expect(entries.compactMap(\.itemId) == ["one", "two", "three"])
        #expect(entries.filter(\.isHeader).count == 2)
    }

    /// Identity drives whether the table reloads. A refilter that lands on the same rows must
    /// compare equal, or every keystroke would throw away the hosted views.
    @Test("Identity is stable across rebuilds of the same rows")
    func identityIsStable() {
        let first = FieldDrivenListEntry.flatten([section("a", title: "ACTIVE", ["one", "two"])])
        let second = FieldDrivenListEntry.flatten([section("a", title: "ACTIVE", ["one", "two"])])
        #expect(first.map(\.identity) == second.map(\.identity))
    }

    @Test("Identity changes when the rows change")
    func identityTracksContent() {
        let first = FieldDrivenListEntry.flatten([section("a", title: nil, ["one", "two"])])
        let second = FieldDrivenListEntry.flatten([section("a", title: nil, ["one"])])
        #expect(first.map(\.identity) != second.map(\.identity))
    }

    /// Only item rows are refreshed in place, so a header that keeps its identity keeps whatever
    /// it was already drawing. A group renamed on another device would have stayed on screen under
    /// its old name.
    @Test("A renamed section is a different header")
    func headerIdentityFollowsItsTitle() {
        let before = FieldDrivenListEntry.flatten([section("g", title: "ACME", ["one"])])
        let after = FieldDrivenListEntry.flatten([section("g", title: "ACME CORP", ["one"])])

        #expect(before.map(\.identity) != after.map(\.identity))
    }

    @Test("A recoloured section is a different header")
    func headerIdentityFollowsItsAccent() {
        let plain = FieldDrivenListSection(id: "g", title: "ACME", items: [Item(id: "one")])
        let coloured = FieldDrivenListSection(
            id: "g",
            title: "ACME",
            accentColor: .systemRed,
            items: [Item(id: "one")]
        )

        #expect(
            FieldDrivenListEntry.flatten([plain]).map(\.identity)
                != FieldDrivenListEntry.flatten([coloured]).map(\.identity)
        )
    }

    @Test("A header never reports an item id")
    func headerHasNoItemId() {
        let entries = FieldDrivenListEntry.flatten([section("a", title: "ACTIVE", ["one"])])
        let headers = entries.filter(\.isHeader)
        #expect(headers.count == 1)
        #expect(headers[0].itemId == nil)
    }
}
