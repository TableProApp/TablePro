import Foundation
@testable import TablePro
import Testing

@Suite("TabQueryContent.Equatable")
struct TabQueryContentEqualityTests {
    @Test("Equal when all fields match")
    func equalWhenIdentical() {
        let a = TabQueryContent(query: "SELECT * FROM users;")
        let b = TabQueryContent(query: "SELECT * FROM users;")
        #expect(a == b)
    }

    @Test("Not equal when the query changes length")
    func notEqualOnLengthChange() {
        var a = TabQueryContent(query: "SELECT 1")
        let b = TabQueryContent(query: "SELECT 12")
        #expect(a != b)
        a.query = "SELECT 12"
        #expect(a == b)
    }

    @Test("Not equal when the query changes at the same length")
    func notEqualOnSameLengthChange() {
        let a = TabQueryContent(query: "abc")
        let b = TabQueryContent(query: "abd")
        #expect(a != b)
    }

    @Test("Detects a single-character edit in a large query")
    func detectsEditInLargeQuery() {
        let base = String(repeating: "SELECT 1;\n", count: 100_000)
        let a = TabQueryContent(query: base)
        let b = TabQueryContent(query: base + "X")
        #expect(a != b)
        let c = TabQueryContent(query: base)
        #expect(a == c)
    }

    @Test("Not equal when a non-text field differs")
    func notEqualOnOtherField() {
        var a = TabQueryContent(query: "Q")
        let b = TabQueryContent(query: "Q")
        a.isParameterPanelVisible = true
        #expect(a != b)
        a.isParameterPanelVisible = false
        #expect(a == b)
    }

    @Test("savedFileContent participates in equality")
    func savedFileContentEquality() {
        var a = TabQueryContent(query: "Q")
        var b = TabQueryContent(query: "Q")
        #expect(a == b)
        a.savedFileContent = "disk"
        #expect(a != b)
        b.savedFileContent = "disk"
        #expect(a == b)
        b.savedFileContent = "other"
        #expect(a != b)
    }

    @Test("Value semantics: mutating a copy does not change the original")
    func valueSemantics() {
        let a = TabQueryContent(query: "original")
        var b = a
        b.query = "changed"
        #expect(a.query == "original")
        #expect(b.query == "changed")
        #expect(a != b)
    }
}
