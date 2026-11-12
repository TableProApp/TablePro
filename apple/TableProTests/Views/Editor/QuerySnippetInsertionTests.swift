//
//  QuerySnippetInsertionTests.swift
//  TableProTests
//
//  A saved query chosen from the query bar's Snippets menu goes into the editor the way completion
//  puts in a favorite: tab stops become fields and `;;` marks where the caret lands.
//

import AppKit
import TableProEditorKit
import TableProTextEngine
import Testing

@testable import TablePro

@MainActor
struct QuerySnippetInsertionTests {
    private let controller = EditorControllerFixture.make(string: "SELECT 1;\n")

    private var text: String { controller.textView.string }

    private var selection: [NSRange] {
        controller.textView.selectionManager.textSelections.map { $0.range }
    }

    private func select(_ range: NSRange) {
        controller.textView.selectionManager.setSelectedRange(range)
    }

    @Test("Tab stops expand into fields and the first one is selected for typing")
    func expandsTabStops() {
        select(NSRange(location: 10, length: 0))

        QuerySnippetInsertion.insert("SELECT * FROM ${1:orders} WHERE ${2:id} = 1", into: controller)

        #expect(text == "SELECT 1;\nSELECT * FROM orders WHERE id = 1")
        #expect(controller.isSnippetSessionActive)
        #expect(selection == [NSRange(location: 24, length: 6)])
    }

    @Test("The ;; marker is removed and the caret lands where it stood")
    func markerPlacesTheCaret() {
        select(NSRange(location: 10, length: 0))

        QuerySnippetInsertion.insert("SELECT * FROM users WHERE ;; LIMIT 10", into: controller)

        #expect(text == "SELECT 1;\nSELECT * FROM users WHERE  LIMIT 10")
        #expect(selection == [NSRange(location: 36, length: 0)])
    }

    @Test("A query with no placeholder goes in as written, caret after it")
    func plainQuery() {
        select(NSRange(location: 10, length: 0))

        QuerySnippetInsertion.insert("SELECT 2", into: controller)

        #expect(text == "SELECT 1;\nSELECT 2")
        #expect(!controller.isSnippetSessionActive)
        #expect(selection == [NSRange(location: 18, length: 0)])
    }

    @Test("A selection is replaced, as typing would replace it")
    func replacesTheSelection() {
        select(NSRange(location: 7, length: 1))

        QuerySnippetInsertion.insert("count(*)", into: controller)

        #expect(text == "SELECT count(*);\n")
    }

    /// The parse is completion's own, so a PostgreSQL parameter is not mistaken for a tab stop.
    @Test("A bare $1 stays a parameter, as it does when completion inserts the favorite")
    func dollarParameterStaysLiteral() {
        let snippet = QuerySnippetInsertion.snippet(for: "SELECT * FROM orders WHERE id = $1")

        #expect(snippet.text == "SELECT * FROM orders WHERE id = $1")
        #expect(snippet.fields.isEmpty)
        #expect(snippet.finalRange == nil)
    }
}
