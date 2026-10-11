import Foundation
import Testing

@testable import TablePro

struct ForeignKeyLabelTextTests {
    @Test("Two values read as one line")
    func twoValuesJoin() {
        #expect(ForeignKeyLabelText.joined(["integrale", "caputo"]) == "integrale, caputo")
    }

    @Test("One value is itself")
    func oneValueIsItself() {
        #expect(ForeignKeyLabelText.joined(["caputo"]) == "caputo")
    }

    /// A gap where a value should be reads as a missing word twice over: the value and the one
    /// beside it both look wrong.
    @Test("A NULL in the middle leaves no double separator")
    func nullInTheMiddleIsSkipped() {
        #expect(ForeignKeyLabelText.joined(["integrale", nil, "nero"]) == "integrale, nero")
    }

    @Test("An empty value is skipped the same way a NULL is")
    func emptyValueIsSkipped() {
        #expect(ForeignKeyLabelText.joined(["integrale", "", "nero"]) == "integrale, nero")
    }

    @Test("A row with nothing to show carries no label at all")
    func nothingToShowIsNoLabel() {
        #expect(ForeignKeyLabelText.joined([]) == nil)
        #expect(ForeignKeyLabelText.joined([nil, nil]) == nil)
        #expect(ForeignKeyLabelText.joined([""]) == nil)
    }
}
