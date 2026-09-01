//
//  JSONRowFilterTests.swift
//  TableProTests
//
//  A filter keeps what matched and the keys that lead to it.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("JSONRowFilter")
struct JSONRowFilterTests {
    private func makeRoot() -> JSONRowNode {
        JSONRowNodeBuilder.build(
            columns: ["title", "length", "special_features"],
            values: [.text("ANYTHING SAVANNAH"), .text("82"), .text("[\"Trailers\", \"Deleted Scenes\"]")],
            columnTypes: [.text(rawType: "VARCHAR"), .integer(rawType: "INT"), .json(rawType: "JSON")],
            foreignKeys: [:]
        )
    }

    private func matcher(_ query: String) throws -> JSONRowMatcher {
        guard case .matcher(let matcher) = JSONRowMatcher.make(query: query) else {
            throw FilterTestError.notAMatcher
        }
        return matcher
    }

    private enum FilterTestError: Error {
        case notAMatcher
    }

    @Test("An empty query is not a filter")
    func emptyQuery() {
        if case .empty = JSONRowMatcher.make(query: "   ") { return }
        Issue.record("Whitespace should read as no filter")
    }

    @Test("A key match keeps the key")
    func matchesKeys() throws {
        let visible = JSONRowFilter.visiblePaths(
            root: makeRoot(),
            fetchedForeignKeys: [:],
            matcher: try matcher("length")
        )
        #expect(visible.contains(JSONNodePath.root.appending("length")))
        #expect(visible.contains(JSONNodePath.root.appending("title")) == false)
    }

    @Test("A value match keeps the key that holds it")
    func matchesValues() throws {
        let visible = JSONRowFilter.visiblePaths(
            root: makeRoot(),
            fetchedForeignKeys: [:],
            matcher: try matcher("savannah")
        )
        #expect(visible.contains(JSONNodePath.root.appending("title")))
    }

    @Test("A nested match keeps its ancestors")
    func keepsAncestors() throws {
        let root = makeRoot()
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("Deleted")
        )
        #expect(visible.contains(root.path))
        #expect(visible.contains(JSONNodePath.root.appending("special_features")))
        #expect(visible.contains(JSONNodePath.root.appending("title")) == false)
    }

    @Test("Slashes make the query a regular expression")
    func readsRegex() throws {
        let visible = JSONRowFilter.visiblePaths(
            root: makeRoot(),
            fetchedForeignKeys: [:],
            matcher: try matcher("/^len/")
        )
        #expect(visible.contains(JSONNodePath.root.appending("length")))
        #expect(visible.contains(JSONNodePath.root.appending("title")) == false)
    }

    @Test("A broken regular expression is reported, not treated as text")
    func reportsInvalidRegex() {
        if case .invalidRegex = JSONRowMatcher.make(query: "/[/") { return }
        Issue.record("An unclosed class should report as invalid")
    }

    @Test("Text that only looks like a path stays a substring")
    func treatsPathsAsSubstrings() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["path"],
            values: [.text("a/b")],
            columnTypes: [.text(rawType: "TEXT")],
            foreignKeys: [:]
        )
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("a/b")
        )
        #expect(visible.contains(JSONNodePath.root.appending("path")))
    }

    @Test("A fetched foreign key's own keys are searched")
    func searchesFetchedForeignKeys() throws {
        let reference = JSONForeignKeyRef(
            column: "language_id",
            referencedTable: "language",
            referencedSchema: nil,
            referencedColumn: "language_id"
        )
        let root = JSONRowNodeBuilder.build(
            columns: ["language_id"],
            values: [.text("1")],
            columnTypes: [.integer(rawType: "INT")],
            foreignKeys: ["language_id": reference]
        )
        let keyPath = JSONNodePath.root.appending("language_id")
        let expansion = JSONRowNodeBuilder.build(
            path: keyPath,
            key: .name("language_id"),
            columns: ["name"],
            values: [.text("English")],
            columnTypes: [.text(rawType: "CHAR")],
            foreignKeys: [:]
        )

        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [keyPath: expansion],
            matcher: try matcher("English")
        )
        #expect(visible.contains(keyPath.appending("name")))
        #expect(visible.contains(keyPath))
    }
}
