import Foundation
import Testing

@testable import TablePro

@Suite("ForeignKeyPickerEntry")
struct ForeignKeyPickerEntryTests {
    private let integerKey = ColumnType.integer(rawType: "INTEGER")
    private let textKey = ColumnType.text(rawType: "VARCHAR(8)")

    private func rows(_ pairs: [(String, String?)]) -> [ForeignKeyLookupService.Row] {
        pairs.enumerated().map { ForeignKeyLookupService.Row(id: $0.offset, key: $0.element.0, label: $0.element.1) }
    }

    private func entry(_ index: Int, _ key: String, _ label: String?) -> ForeignKeyPickerEntry {
        .row(ForeignKeyLookupService.Row(id: index, key: key, label: label))
    }

    private func build(
        _ pairs: [(String, String?)],
        term: String,
        keyType: ColumnType?
    ) -> [ForeignKeyPickerEntry] {
        ForeignKeyPickerEntry.build(rows: rows(pairs), term: term, keyType: keyType)
    }

    @Test("An empty term lists the rows alone")
    func emptyTermListsRowsAlone() {
        let entries = build([("1", "AC/DC"), ("2", "Accept")], term: "", keyType: integerKey)
        #expect(entries == [entry(0, "1", "AC/DC"), entry(1, "2", "Accept")])
    }

    @Test("A numeric term on a numeric key leads the list")
    func numericTermLeadsOnNumericKey() {
        let entries = build([("42", "Big Ones")], term: "7", keyType: integerKey)
        #expect(entries.first == .literal("7"))
    }

    /// A word typed against a numeric key is a search for a label. Offering it as a value, selected,
    /// made the obvious keystroke write the search term into an integer column.
    @Test("A word on a numeric key is never offered as a value")
    func wordIsNotOfferedOnNumericKey() {
        let entries = build([("5", "Big Ones")], term: "Big", keyType: integerKey)
        #expect(entries == [entry(0, "5", "Big Ones")])
    }

    @Test("A word on a text key is offered, because it could be the key")
    func wordIsOfferedOnTextKey() {
        let entries = build([("BIG", "Big Ones")], term: "Big", keyType: textKey)
        #expect(entries.first == .literal("Big"))
    }

    @Test("An unknown key type takes the term on trust")
    func unknownKeyTypeAcceptsAnything() {
        #expect(ForeignKeyPickerEntry.acceptsTypedKey("Big", keyType: nil))
    }

    @Test("A term that already names a listed key is not repeated")
    func exactKeyIsNotRepeated() {
        let entries = build([("7", "Seven")], term: "7", keyType: integerKey)
        #expect(entries == [entry(0, "7", "Seven")])
    }

    @Test("Whitespace around the term is trimmed before it becomes a value")
    func termIsTrimmed() {
        let entries = build([], term: "  7 ", keyType: integerKey)
        #expect(entries == [.literal("7")])
    }

    // MARK: - Default selection

    private func selection(
        _ pairs: [(String, String?)],
        term: String,
        keyType: ColumnType?,
        currentValue: String? = nil
    ) -> ForeignKeyPickerEntry.ID? {
        ForeignKeyPickerEntry.defaultSelection(
            in: build(pairs, term: term, keyType: keyType),
            term: term,
            currentValue: currentValue
        )
    }

    @Test("The typed term is selected when it is offered")
    func typedTermIsSelected() {
        #expect(
            selection([("1", "AC/DC")], term: "7", keyType: integerKey)
                == ForeignKeyPickerEntry.literal("7").id
        )
    }

    /// A search for `42` also matches every label containing 42, and those sort ahead of the key
    /// itself whenever the key is longer, so the row the user asked for has to be named.
    @Test("An exact key wins over the head of the list")
    func exactKeyWinsOverTheFirstRow() {
        let rows = [("7", "Track 42" as String?), ("42", "Big Ones" as String?)]
        #expect(
            selection(rows, term: "42", keyType: integerKey)
                == entry(1, "42", "Big Ones").id
        )
    }

    @Test("A search that narrows to one row selects that row")
    func narrowedSearchSelectsTheRow() {
        #expect(
            selection([("5", "Big Ones")], term: "Big", keyType: integerKey)
                == entry(0, "5", "Big Ones").id
        )
    }

    @Test("An empty list selects nothing")
    func emptyListSelectsNothing() {
        #expect(ForeignKeyPickerEntry.defaultSelection(in: [], term: "Big", currentValue: nil) == nil)
    }

    /// Opening the picker and pressing Return used to write the first row of the referenced table
    /// over the key already in the cell, because an unfiltered list preselected its head.
    @Test("With nothing typed the cell's own value is selected")
    func currentValueIsSelectedOnOpen() {
        let rows = [("1", "AC/DC" as String?), ("5", "Big Ones" as String?)]
        #expect(
            selection(rows, term: "", keyType: integerKey, currentValue: "5")
                == entry(1, "5", "Big Ones").id
        )
    }

    @Test("With nothing typed and no current value nothing is selected")
    func nothingIsSelectedWithoutACurrentValue() {
        #expect(selection([("1", "AC/DC")], term: "", keyType: integerKey) == nil)
    }

    @Test("A current value the first page does not reach selects nothing")
    func unreachedCurrentValueSelectsNothing() {
        #expect(selection([("1", "AC/DC")], term: "", keyType: integerKey, currentValue: "900") == nil)
    }

    /// A foreign key may reference one column of a composite unique key, which is not unique on its
    /// own, so two rows can carry the same key and the list has to keep them apart.
    @Test("Two rows with the same key keep separate identities")
    func duplicateKeysStayDistinct() {
        let entries = build([("5", "Big Ones"), ("5", "Bigger Ones")], term: "", keyType: integerKey)
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test("The committed value of a row is its key, never its label")
    func committedValueIsTheKey() {
        #expect(entry(0, "5", "Big Ones").committedValue == "5")
        #expect(ForeignKeyPickerEntry.literal("7").committedValue == "7")
    }
}
