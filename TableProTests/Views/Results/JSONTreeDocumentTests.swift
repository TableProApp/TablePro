//
//  JSONTreeDocumentTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct JSONTreeDocumentTests {
    private enum Outcome: Equatable {
        case emptyValue
        case tree
        case tooLarge
        case invalidJSON
    }

    private func outcome(_ document: JSONTreeDocument) -> Outcome {
        switch document {
        case .emptyValue: return .emptyValue
        case .tree: return .tree
        case .unavailable(.tooLarge): return .tooLarge
        case .unavailable(.invalidJSON): return .invalidJSON
        }
    }

    private func minifiedRows(_ count: Int) -> String {
        let rows = (0..<count).map { #"{"id":\#(1_000 + $0),"sku":"A-\#(1_000 + $0)","qty":3}"# }
        return "[\(rows.joined(separator: ","))]"
    }

    private func length(_ text: String) -> Int {
        (text as NSString).length
    }

    // MARK: - Size cap

    @Test("a minified value under the cap opens as a tree once the viewer has indented it past the cap")
    func sizeCapCountsTheCompactDocument() {
        let stored = minifiedRows(2_600)
        let displayText = JsonReindenter.reindent(stored)
        #expect(length(stored) < 100_000)
        #expect(length(displayText) > 100_000)

        guard case .tree(let root) = JSONTreeDocument(displayText: displayText) else {
            Issue.record("expected a tree, got \(outcome(JSONTreeDocument(displayText: displayText)))")
            return
        }
        #expect(root.children.first?.children.first?.rawValue == "1000")
    }

    @Test("a document over the cap in compact form is still too large")
    func compactDocumentOverTheCapIsTooLarge() {
        let stored = minifiedRows(2_900)
        #expect(length(stored) > 100_000)

        #expect(outcome(JSONTreeDocument(displayText: JsonReindenter.reindent(stored))) == .tooLarge)
        #expect(outcome(JSONTreeDocument(displayText: stored)) == .tooLarge)
    }

    @Test("parse measures the compact form of the text it is given")
    func parseMeasuresTheCompactText() {
        let displayText = JsonReindenter.reindent(minifiedRows(2_600))

        guard case .success = JSONTreeDocument.parse(displayText) else {
            Issue.record("expected the indented document to parse")
            return
        }
        guard case .failure(.tooLarge) = JSONTreeDocument.parse(JsonReindenter.reindent(minifiedRows(2_900))) else {
            Issue.record("expected the cap to hold for a document that is too large in compact form")
            return
        }
    }

    // MARK: - Empty value

    @Test(
        "a value with nothing in it is empty, not invalid",
        arguments: ["", " ", "   ", "\n", "\t \r\n", "\u{00A0}"]
    )
    func blankTextIsAnEmptyValue(text: String) {
        #expect(outcome(JSONTreeDocument(displayText: text)) == .emptyValue)
    }

    @Test(
        "blank text over the size cap is too large, so the blank check never reads all of it",
        arguments: [25_001, 2_500_000]
    )
    func oversizedBlankTextIsTooLarge(repeats: Int) {
        let text = String(repeating: " \t\n\u{00A0}", count: repeats)
        #expect(length(text) > 100_000)

        #expect(outcome(JSONTreeDocument(displayText: text)) == .tooLarge)
    }

    @Test("blank text at the size cap is still an empty value")
    func blankTextAtTheCapIsEmpty() {
        #expect(outcome(JSONTreeDocument(displayText: String(repeating: " ", count: 100_000))) == .emptyValue)
    }

    @Test("JSON null, an empty object and an empty string are values, not an empty cell")
    func emptyLookingDocumentsAreTrees() {
        #expect(outcome(JSONTreeDocument(displayText: "null")) == .tree)
        #expect(outcome(JSONTreeDocument(displayText: "{}")) == .tree)
        #expect(outcome(JSONTreeDocument(displayText: " [] ")) == .tree)
        #expect(outcome(JSONTreeDocument(displayText: "\"\"")) == .tree)
    }

    @Test("text that is not JSON still reads as invalid")
    func brokenTextIsInvalid() {
        #expect(outcome(JSONTreeDocument(displayText: "{\"a\":")) == .invalidJSON)
        #expect(outcome(JSONTreeDocument(displayText: "not json")) == .invalidJSON)
    }
}
