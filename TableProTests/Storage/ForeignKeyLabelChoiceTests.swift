import Foundation
import Testing

@testable import TablePro

struct ForeignKeyLabelChoiceTests {
    private func roundTrip(_ choice: ForeignKeyLabelChoice) -> ForeignKeyLabelChoice {
        ForeignKeyLabelChoice(storedData: choice.storedData)
    }

    @Test("No stored value is no answer")
    func absentIsUnset() {
        #expect(ForeignKeyLabelChoice(storedData: nil) == .unset)
        #expect(ForeignKeyLabelChoice.unset.storedData == nil)
    }

    @Test("Choosing no label round-trips")
    func noLabelRoundTrips() {
        #expect(roundTrip(.noLabel) == .noLabel)
    }

    @Test("One column round-trips")
    func oneColumnRoundTrips() {
        #expect(roundTrip(.columns(["Name"])) == .columns(["Name"]))
    }

    @Test("Several columns round-trip in order")
    func severalColumnsRoundTrip() {
        let choice = ForeignKeyLabelChoice.columns(["descrizione", "marchio", "note"])
        #expect(roundTrip(choice) == choice)
    }

    /// The single-name form is bare UTF-8 with no sentinel, which is what every choice made before
    /// this was written looks like on disk. It has to keep reading as the one column it names.
    @Test("A choice stored before this took a list reads as the one column it names")
    func legacySingleNameDecodes() {
        #expect(ForeignKeyLabelChoice(storedData: Data("Name".utf8)) == .columns(["Name"]))
    }

    @Test("The no-label sentinel a previous build wrote still reads as no label")
    func legacyNoLabelSentinelDecodes() {
        #expect(ForeignKeyLabelChoice(storedData: Data([0xFF])) == .noLabel)
    }

    /// A comma is a legal column name on every engine the app speaks to, so the encoding can never
    /// be a comma-joined string.
    @Test("A column name containing the separator survives")
    func nameContainingACommaSurvives() {
        let choice = ForeignKeyLabelChoice.columns(["last, first", "code"])
        #expect(roundTrip(choice) == choice)
    }

    /// A name spelled like the encoding itself has to come back as that name, not as a list.
    @Test("A column name spelled like a JSON array survives")
    func nameSpelledLikeJsonSurvives() {
        let choice = ForeignKeyLabelChoice.columns(["[\"x\"]"])
        #expect(roundTrip(choice) == choice)
    }

    /// SQLite accepts `create table t("" integer)`, so a zero-length name is one a reader can pick.
    @Test("An empty column name is a name")
    func emptyNameIsAName() {
        #expect(roundTrip(.columns([""])) == .columns([""]))
        #expect(ForeignKeyLabelChoice(storedData: Data()) == .columns([""]))
    }

    @Test("Choosing nothing is choosing no label")
    func emptyListBecomesNoLabel() {
        #expect(ForeignKeyLabelChoice(columnNames: []) == .noLabel)
        #expect(ForeignKeyLabelChoice.columns([]).storedData == ForeignKeyLabelChoice.noLabel.storedData)
    }

    /// The same column twice would select it twice and read as a repeated value.
    @Test("A column named twice is kept once, at its first mention")
    func duplicatesCollapse() {
        #expect(ForeignKeyLabelChoice(columnNames: ["b", "a", "b"]) == .columns(["b", "a"]))
    }

    /// A payload the app cannot read is no answer rather than a column name, because the name
    /// reaches the query as a quoted identifier.
    @Test("An unreadable payload is no answer")
    func unreadablePayloadIsUnset() {
        #expect(ForeignKeyLabelChoice(storedData: Data([0xFE, 0x7B])) == .unset)
        #expect(ForeignKeyLabelChoice(storedData: Data([0xFF, 0xFF])) == .unset)
        #expect(ForeignKeyLabelChoice(storedData: Data([0xC3, 0x28])) == .unset)
    }

    @Test("Column names are readable straight off the choice")
    func columnNamesAreReadable() {
        #expect(ForeignKeyLabelChoice.columns(["a", "b"]).columnNames == ["a", "b"])
        #expect(ForeignKeyLabelChoice.noLabel.columnNames.isEmpty)
        #expect(ForeignKeyLabelChoice.unset.columnNames.isEmpty)
    }
}
