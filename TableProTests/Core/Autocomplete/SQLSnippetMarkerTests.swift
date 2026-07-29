//
//  SQLSnippetMarkerTests.swift
//  TableProTests
//
//  Tests for SQLSnippetMarker: the ";;" cursor token stripped from a
//  favorite's query on keyword expansion. Offsets must be UTF-16 units so a
//  marker after multibyte text still lands the caret correctly.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLSnippetMarker")
struct SQLSnippetMarkerTests {
    @Test("Query without a marker expands to nil")
    func noMarkerReturnsNil() {
        #expect(SQLSnippetMarker.expand("SELECT * FROM users") == nil)
    }

    @Test("Empty query expands to nil")
    func emptyQueryReturnsNil() {
        #expect(SQLSnippetMarker.expand("") == nil)
    }

    @Test("Marker at the start strips and places the caret at zero")
    func markerAtStart() {
        let expansion = SQLSnippetMarker.expand(";;SELECT 1")
        #expect(expansion?.text == "SELECT 1")
        #expect(expansion?.cursorOffset == 0)
    }

    @Test("Marker in the middle strips and places the caret at its position")
    func markerInMiddle() {
        let expansion = SQLSnippetMarker.expand("SELECT ;; FROM users")
        #expect(expansion?.text == "SELECT  FROM users")
        #expect(expansion?.cursorOffset == 7)
    }

    @Test("Marker at the end places the caret after the stripped text")
    func markerAtEnd() {
        let expansion = SQLSnippetMarker.expand("SELECT 1;;")
        #expect(expansion?.text == "SELECT 1")
        #expect(expansion?.cursorOffset == 8)
    }

    @Test("Only the first marker is stripped, later ones stay literal")
    func firstMarkerWins() {
        let expansion = SQLSnippetMarker.expand("WHERE a = ;; AND b = ;;")
        #expect(expansion?.text == "WHERE a =  AND b = ;;")
        #expect(expansion?.cursorOffset == 10)
    }

    @Test("Marker offset counts UTF-16 units after multibyte text")
    func markerAfterMultibyteText() {
        let prefix = "-- ghi chú 🙂\nSELECT * FROM t WHERE x = "
        let expansion = SQLSnippetMarker.expand(prefix + ";;")
        #expect(expansion?.text == prefix)
        #expect(expansion?.cursorOffset == (prefix as NSString).length)
    }

    @Test("The issue #1795 template resolves to the caret after the alias dot")
    func issueTemplate() {
        let expansion = SQLSnippetMarker.expand("SELECT COUNT(*)\nFROM  alias\nWHERE alias.;;")
        let expected = "SELECT COUNT(*)\nFROM  alias\nWHERE alias."
        #expect(expansion?.text == expected)
        #expect(expansion?.cursorOffset == (expected as NSString).length)
    }
}
