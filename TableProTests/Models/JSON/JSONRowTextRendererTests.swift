//
//  JSONRowTextRendererTests.swift
//  TableProTests
//
//  Copy Visible writes the lines that are on screen, not the whole row.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("JSONRowTextRenderer")
struct JSONRowTextRendererTests {
    private func makeRoot() -> JSONRowNode {
        JSONRowNodeBuilder.build(
            columns: ["film_id", "title", "special_features", "note"],
            values: [.text("2"), .text("ACE \"GOLDFINGER\""), .text("[\"Trailers\"]"), .null],
            columnTypes: [
                .integer(rawType: "INT"),
                .text(rawType: "VARCHAR"),
                .json(rawType: "JSON"),
                .text(rawType: "TEXT"),
            ],
            foreignKeys: [:]
        )
    }

    @Test("Renders the expanded tree as JSON")
    func rendersExpandedTree() {
        let root = makeRoot()
        let rows = JSONRowFlattener.rows(
            root: root,
            expanded: [root.path, root.children[2].path],
            states: JSONForeignKeyStates()
        )
        #expect(JSONRowTextRenderer.render(rows: rows) == """
        {
          "film_id": 2,
          "title": "ACE \\"GOLDFINGER\\"",
          "special_features": [
            "Trailers"
          ],
          "note": null
        }
        """)
    }

    @Test("A collapsed container prints as an ellipsis, the way it is shown")
    func rendersCollapsedContainer() {
        let root = makeRoot()
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(JSONRowTextRenderer.render(rows: rows).contains("\"special_features\": […],"))
    }
}
