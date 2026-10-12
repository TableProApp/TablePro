//
//  SymbolPickerModelTests.swift
//  TableProTests
//

import Foundation
import TableProConnectionLibrary
import Testing

@testable import TablePro

struct SymbolPickerModelTests {
    private func names(in model: SymbolPickerModel) -> [String] {
        model.sections.flatMap(\.symbols).map(\.name)
    }

    // MARK: - Opening

    @Test("No icon opens on the Default cell, which is the current one")
    func nilSelectionHighlightsDefault() {
        let model = SymbolPickerModel(selection: nil)

        #expect(model.highlight == .defaultIcon)
        #expect(model.isSelected(.defaultIcon))
        #expect(model.items.first == .defaultIcon)
    }

    @Test("A catalog icon opens highlighted and marked current")
    func catalogSelectionIsHighlighted() {
        let model = SymbolPickerModel(selection: "server.rack")

        #expect(model.highlight == .symbol("server.rack"))
        #expect(model.isSelected(.symbol("server.rack")))
        #expect(!model.isSelected(.defaultIcon))
    }

    /// A newer release can sync a name this catalog does not list. It is kept as stored, and the
    /// picker claims no cell for it until the user picks one.
    @Test("An icon the catalog does not list selects no cell")
    func unknownSelectionSelectsNothing() {
        let model = SymbolPickerModel(selection: "made.up.symbol")

        #expect(model.selection == "made.up.symbol")
        #expect(model.highlight == nil)
        #expect(!model.items.contains { model.isSelected($0) })
    }

    // MARK: - Filtering

    @Test("A query matches a title")
    func filtersByTitle() {
        var model = SymbolPickerModel(selection: nil)
        model.query = "Server"

        #expect(names(in: model) == ["server.rack"])
    }

    @Test("A query matches a keyword")
    func filtersByKeyword() {
        var model = SymbolPickerModel(selection: nil)
        model.query = "redis"

        #expect(names(in: model) == ["memorychip"])
    }

    @Test("A query matches a token of the symbol name")
    func filtersByNameToken() {
        var model = SymbolPickerModel(selection: nil)
        model.query = "connected"

        #expect(names(in: model).contains("externaldrive.connected.to.line.below"))
    }

    @Test("Default shows for an empty query and for one that matches its title, and hides otherwise")
    func defaultCellFollowsTheQuery() {
        var model = SymbolPickerModel(selection: nil)
        #expect(model.showsDefault)

        model.query = "Server"
        #expect(!model.showsDefault)
        #expect(model.items.first == .symbol("server.rack"))

        model.query = String(SymbolPickerModel.defaultTitle.prefix(3))
        #expect(model.showsDefault)
        #expect(model.items.first == .defaultIcon)
    }

    @Test("A query that matches nothing leaves the grid empty and nothing to commit")
    func noMatchIsEmpty() {
        var model = SymbolPickerModel(selection: "server.rack")
        model.query = "zzzz"

        #expect(model.isEmpty)
        #expect(model.highlight == nil)
        #expect(model.commit() == nil)
    }

    // MARK: - Highlight

    @Test("A highlight the query still shows is kept, even when another cell is the best match")
    func keepsAVisibleHighlight() {
        var model = SymbolPickerModel(selection: "hare")
        model.query = "cache"

        #expect(names(in: model) == ["memorychip", "hare"])
        #expect(model.highlight == .symbol("hare"))
    }

    @Test("A query that hides the highlight arms its best match")
    func armsTheBestMatch() {
        var model = SymbolPickerModel(selection: nil)
        model.query = "Server"

        #expect(model.highlight == .symbol("server.rack"))
    }

    @Test("A query that matched only inside words arms nothing rather than the first cell")
    func substringOnlyMatchArmsNothing() {
        var model = SymbolPickerModel(selection: nil)
        model.query = "ase"

        #expect(!model.isEmpty)
        #expect(model.highlight == nil)
        #expect(model.commit() == nil)
    }

    @Test("Default's own title outranks a keyword that starts the same way")
    func defaultOutranksAKeywordPrefix() {
        var model = SymbolPickerModel(selection: "server.rack")
        model.query = String(SymbolPickerModel.defaultTitle.prefix(3))

        #expect(model.highlight == .defaultIcon)
        #expect(model.commit() == .defaultIcon)
    }

    @Test("Clearing the query highlights the current icon again")
    func clearingTheQueryRestoresTheCurrentIcon() {
        var model = SymbolPickerModel(selection: "server.rack")
        model.query = "zzzz"
        model.query = ""

        #expect(model.highlight == .symbol("server.rack"))
    }

    // MARK: - Moving

    @Test("Down from Default lands on the first icon, the cell right under it")
    func downFromDefault() {
        var model = SymbolPickerModel(selection: nil)
        let rows = model.rows

        model.moveDown()
        #expect(model.highlight == rows[1][0])

        model.moveUp()
        #expect(model.highlight == .defaultIcon)
    }

    @Test("Down and Up keep the column across rows")
    func movesKeepTheColumn() {
        var model = SymbolPickerModel(selection: nil)
        let rows = model.rows
        model.highlight = rows[1][3]

        model.moveDown()
        #expect(model.highlight == rows[2][3])

        model.moveUp()
        #expect(model.highlight == rows[1][3])
    }

    @Test("Moving into a shorter row lands on its last cell")
    func movesClampToAShortRow() throws {
        var model = SymbolPickerModel(selection: nil)
        let rows = model.rows
        let shortIndex = try #require(rows.indices.dropFirst().first { rows[$0].count < SymbolPickerModel.columnCount })
        model.highlight = rows[shortIndex - 1][SymbolPickerModel.columnCount - 1]

        model.moveDown()
        #expect(model.highlight == rows[shortIndex].last)
    }

    @Test("A move past either end stops at the end")
    func movesAreClamped() {
        var model = SymbolPickerModel(selection: nil)
        let rows = model.rows

        model.moveUp()
        #expect(model.highlight == .defaultIcon)

        let lastCell = rows[rows.count - 1][0]
        model.highlight = lastCell
        model.moveDown()
        #expect(model.highlight == lastCell)
    }

    @Test("With nothing highlighted, Down starts at the first cell and Up at the last")
    func movingFromNoHighlight() {
        var model = SymbolPickerModel(selection: "made.up.symbol")
        model.moveDown()
        #expect(model.highlight == model.items.first)

        var other = SymbolPickerModel(selection: "made.up.symbol")
        other.moveUp()
        #expect(other.highlight == other.rows.last?.last)
    }

    // MARK: - Commit

    @Test("Commit returns the highlighted icon")
    func commitReturnsTheHighlight() {
        var model = SymbolPickerModel(selection: nil)
        model.query = "redis"

        #expect(model.commit() == .symbol("memorychip"))
        #expect(model.commit()?.iconName == "memorychip")
    }

    @Test("Committing Default stores no icon")
    func committingDefaultStoresNil() {
        var model = SymbolPickerModel(selection: "server.rack")
        model.highlight = .defaultIcon

        let committed = model.commit()
        #expect(committed == .defaultIcon)
        #expect(committed?.iconName == nil)
    }
}
