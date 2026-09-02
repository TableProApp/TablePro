import Foundation
import Testing

@testable import TablePro

@Suite("ForeignKeyLabelColumn")
struct ForeignKeyLabelColumnTests {
    private let key = ForeignKeyLookupColumn(name: "id", type: .integer(rawType: "INTEGER"))

    private func text(_ name: String) -> ForeignKeyLookupColumn {
        ForeignKeyLookupColumn(name: name, type: .text(rawType: "VARCHAR(64)"))
    }

    private func resolve(_ columns: [ForeignKeyLookupColumn], preferred: String? = nil) -> String? {
        ForeignKeyLabelColumn.resolve(columns: columns, keyColumn: "id", preferred: preferred)?.name
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
        #expect(resolve([key]) == nil)
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
        #expect(resolve([key, text("name"), text("email")], preferred: "email") == "email")
    }

    /// The stored name reaches the query as a quoted identifier. A preference left behind by a
    /// dropped column, or written into defaults by hand, must never become one.
    @Test("A stored choice the table no longer has falls back to the heuristic")
    func storedChoiceMustExist() {
        #expect(resolve([key, text("name")], preferred: "dropped_column") == "name")
        #expect(resolve([key, text("name")], preferred: "\" OR 1=1 --") == "name")
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
        #expect(resolve(columns, preferred: "score") == "score")
    }
}
