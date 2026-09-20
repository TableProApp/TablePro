import Foundation
import Testing

@testable import TablePro

@Suite("ForeignKeyLabelColumn")
struct ForeignKeyLabelColumnTests {
    private let key = ForeignKeyLookupColumn(name: "id", type: .integer(rawType: "INTEGER"))

    private func text(_ name: String) -> ForeignKeyLookupColumn {
        ForeignKeyLookupColumn(name: name, type: .text(rawType: "VARCHAR(64)"))
    }

    private func resolve(
        _ columns: [ForeignKeyLookupColumn],
        choice: ForeignKeyLabelChoice = .unset
    ) -> String? {
        resolveAll(columns, choice: choice).first
    }

    private func resolveAll(
        _ columns: [ForeignKeyLookupColumn],
        choice: ForeignKeyLabelChoice = .unset
    ) -> [String] {
        ForeignKeyLabelColumn.resolve(columns: columns, keyColumn: "id", choice: choice).map(\.name)
    }

    @Test("A preferred name wins over the column order")
    func preferredNameWins() {
        #expect(resolve([key, text("slug"), text("name")]) == "name")
    }

    @Test("The preferred names are tried in their own order, not the table's")
    func preferredNamesKeepTheirOwnOrder() {
        #expect(resolve([key, text("description"), text("title")]) == "title")
    }

    @Test("A preferred name matches whatever case the column is declared in")
    func preferredNameIgnoresCase() {
        #expect(resolve([key, text("Slug"), text("Name")]) == "Name")
    }

    @Test("Without a preferred name the first text column is taken")
    func firstTextColumnIsTheFallback() {
        #expect(resolve([key, text("slug"), text("bio")]) == "slug")
    }

    @Test("A table of nothing but the key has no label")
    func keyOnlyTableHasNoLabel() {
        #expect(resolveAll([key]).isEmpty)
    }

    /// A `LIKE` against a date or an integer is a type error on a strict engine, so a column the
    /// search cannot use is no use as a label either.
    @Test("A column that is not text is never picked automatically")
    func nonTextColumnsAreNotPicked() {
        let columns = [
            key,
            ForeignKeyLookupColumn(name: "created_at", type: .timestamp(rawType: "TIMESTAMP")),
            ForeignKeyLookupColumn(name: "score", type: .decimal(rawType: "NUMERIC")),
        ]
        #expect(resolve(columns) == nil)
    }

    @Test("A stored choice wins over every heuristic")
    func storedChoiceWins() {
        #expect(resolve([key, text("name"), text("email")], choice: .columns(["email"])) == "email")
    }

    /// The stored name reaches the query as a quoted identifier. A preference left behind by a
    /// dropped column, or written into defaults by hand, must never become one.
    @Test("A stored choice the table no longer has falls back to the heuristic")
    func storedChoiceMustExist() {
        #expect(resolve([key, text("name")], choice: .columns(["dropped_column"])) == "name")
        #expect(resolve([key, text("name")], choice: .columns(["\") OR 1=1 --"])) == "name")
    }

    /// PostgreSQL refuses `LIKE` on an enum or an array, so neither can carry the picker's search
    /// and neither is offered as a label on its own.
    @Test("An enum or an array column is not picked automatically")
    func enumAndArrayColumnsAreNotPicked() {
        let columns = [
            key,
            ForeignKeyLookupColumn(name: "status", type: .enumType(rawType: "status_t", values: nil)),
            ForeignKeyLookupColumn(name: "tags", type: .array(rawType: "text[]", element: .text(rawType: "text"))),
        ]
        #expect(resolve(columns) == nil)
        #expect(resolve(columns + [text("name")]) == "name")
    }

    @Test("A stored choice may be a column the heuristic would have skipped")
    func storedChoiceMayBeNonText() {
        let columns = [key, text("name"), ForeignKeyLookupColumn(name: "score", type: .decimal(rawType: "NUMERIC"))]
        #expect(resolve(columns, choice: .columns(["score"])) == "score")
    }

    @Test("Choosing no label returns no label")
    func explicitNoneReturnsNoLabel() {
        #expect(resolveAll([key, text("name")], choice: .noLabel).isEmpty)
    }

    /// Short-circuits before the candidate scan rather than falling through it, so a table carrying
    /// every preferred name still answers nothing.
    @Test("Choosing no label ignores every candidate")
    func explicitNoneIgnoresEveryCandidate() {
        let columns = [key] + ForeignKeyLabelColumn.preferredNames.map(text)
        #expect(resolveAll(columns, choice: .noLabel).isEmpty)
    }

    // MARK: - Several label columns

    /// The reporter's shape: `alimenti` is only told apart by `descrizione` and `marchio` together,
    /// because that pair is its `UNIQUE` constraint.
    @Test("Every chosen column comes back")
    func everyChosenColumnComesBack() {
        let columns = [key, text("descrizione"), text("marchio"), text("note")]
        #expect(resolveAll(columns, choice: .columns(["descrizione", "marchio"])) == ["descrizione", "marchio"])
    }

    /// The chooser reads in the table's own order, so the label does too and there is no order to
    /// maintain anywhere.
    @Test("Chosen columns come back in the table's order, not the order they were stored in")
    func chosenColumnsFollowTheTableOrder() {
        let columns = [key, text("descrizione"), text("marchio")]
        #expect(resolveAll(columns, choice: .columns(["marchio", "descrizione"])) == ["descrizione", "marchio"])
    }

    @Test("A chosen column the table no longer carries is dropped, and the rest stand")
    func aDroppedColumnLeavesTheRest() {
        let columns = [key, text("name")]
        #expect(resolveAll(columns, choice: .columns(["gone", "name"])) == ["name"])
    }

    /// The key is already the first thing every row shows. Choosing it used to be accepted,
    /// persisted and then silently rendered nothing, for every column pointing at the table.
    @Test("The key column is never a label, however it was stored")
    func theKeyColumnIsNeverALabel() {
        let columns = [key, text("name")]
        #expect(resolveAll(columns, choice: .columns(["id", "name"])) == ["name"])
    }

    /// The old menu listed the key, so choosing it was how a reader reached a key-only list. That
    /// answer stands rather than being read as no answer, which would hand them a label on the
    /// first launch after this.
    @Test("A choice of nothing but the key column is honoured as no label")
    func aKeyOnlyChoiceIsNoLabel() {
        #expect(resolveAll([key, text("name")], choice: .columns(["id"])).isEmpty)
    }

    @Test("The key column is not offered as a choice")
    func theKeyColumnIsNotSelectable() {
        let columns = [key, text("name")]
        #expect(ForeignKeyLabelColumn.selectable(columns, keyColumn: "id").map(\.name) == ["name"])
    }

    /// A choice naming only columns the table has lost is no choice at all, so the heuristic runs
    /// again rather than leaving the reader with bare keys and no way to tell why.
    @Test("A choice of nothing but missing columns falls back to the heuristic")
    func aChoiceOfOnlyMissingColumnsFallsBack() {
        #expect(resolveAll([key, text("name")], choice: .columns(["gone", "also_gone"])) == ["name"])
    }

    @Test("The heuristic still picks exactly one column")
    func theHeuristicPicksOne() {
        #expect(resolveAll([key, text("name"), text("title")]) == ["name"])
    }
}
