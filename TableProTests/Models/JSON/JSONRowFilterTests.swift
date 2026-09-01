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

    /// A column's path carries its position, so a test asks the tree where a key is rather than
    /// spelling the path out.
    private func path(of column: String, in root: JSONRowNode) throws -> JSONNodePath {
        try #require(root.children.first { $0.key == .name(column) }).path
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
        let root = makeRoot()
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("length")
        )
        #expect(visible.contains(try path(of: "length", in: root)))
        #expect(visible.contains(try path(of: "title", in: root)) == false)
    }

    @Test("A value match keeps the key that holds it")
    func matchesValues() throws {
        let root = makeRoot()
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("savannah")
        )
        #expect(visible.contains(try path(of: "title", in: root)))
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
        #expect(visible.contains(try path(of: "special_features", in: root)))
        #expect(visible.contains(try path(of: "title", in: root)) == false)
    }

    @Test("Slashes make the query a regular expression")
    func readsRegex() throws {
        let root = makeRoot()
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("/^len/")
        )
        #expect(visible.contains(try path(of: "length", in: root)))
        #expect(visible.contains(try path(of: "title", in: root)) == false)
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
        #expect(visible.contains(try path(of: "path", in: root)))
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
        let keyPath = try path(of: "language_id", in: root)
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
        let nestedPath = try #require(expansion.children.first).path
        #expect(visible.contains(nestedPath))
        #expect(visible.contains(keyPath))
    }

    /// A container whose own key matches keeps what it holds. Keeping the container alone drew it
    /// as `{…}` with a disclosure control that could not open it, because a filtered tree takes its
    /// expansion from what survived the filter.
    @Test("A container whose key matches keeps its whole subtree")
    func matchedContainerKeepsItsContents() throws {
        let root = makeRoot()
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("special_features")
        )

        let containerPath = try path(of: "special_features", in: root)
        let container = try #require(root.children.first { $0.path == containerPath })
        #expect(visible.contains(containerPath))
        #expect(container.children.allSatisfy { visible.contains($0.path) })
    }

    @Test("A matched container prints open, not as a collapsed placeholder")
    func matchedContainerPrintsExpanded() throws {
        let root = makeRoot()
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("special_features")
        )
        let rows = JSONRowFlattener.rows(
            root: root,
            expanded: [root.path],
            states: JSONForeignKeyStates(),
            visiblePaths: visible
        )

        let container = try #require(rows.first { $0.key == .name("special_features") })
        #expect(container.token == .openArray)
        #expect(container.isExpanded)
    }

    /// A value that matches keeps its own line and the keys that lead to it, never the subtree
    /// under it. An expanded foreign key carries both its own scalar and the referenced row's
    /// fields, so treating a value match as a key match answered a search for the key's value with
    /// every column of the row it points at.
    @Test("A value match keeps its own line, not the rows fetched underneath it")
    func valueMatchDoesNotKeepAFetchedSubtree() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["title", "language_id"],
            values: [.text("ANYTHING SAVANNAH"), .text("1")],
            columnTypes: [.text(rawType: "VARCHAR"), .integer(rawType: "INT")],
            foreignKeys: ["language_id": JSONForeignKeyRef(
                column: "language_id",
                referencedTable: "language",
                referencedSchema: nil,
                referencedColumn: "language_id"
            )]
        )
        let keyPath = try path(of: "language_id", in: root)
        let expansion = JSONRowNodeBuilder.build(
            path: keyPath,
            key: .name("language_id"),
            columns: ["name", "country"],
            values: [.text("English"), .text("Ireland")],
            columnTypes: [.text(rawType: "CHAR"), .text(rawType: "CHAR")],
            foreignKeys: [:]
        )

        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [keyPath: expansion],
            matcher: try matcher("1")
        )

        #expect(visible.contains(keyPath))
        for child in expansion.children {
            #expect(visible.contains(child.path) == false, "A value match must not drag in the fetched row")
        }
    }

    /// The filter runs on every keystroke, so a chain of matching ancestors over one large subtree
    /// has to stay one pass rather than one pass per ancestor.
    @Test("Nested matching containers are visited once each")
    func nestedMatchesDoNotRewalkTheSubtree() throws {
        var document = "{"
        for depth in 0..<40 { document += "\"key\(depth)\": {" }
        document += "\"leaf\": 1"
        document += String(repeating: "}", count: 41)

        let root = JSONRowNodeBuilder.build(
            columns: ["payload"],
            values: [.text(document)],
            columnTypes: [.json(rawType: "JSON")],
            foreignKeys: [:]
        )

        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try matcher("key")
        )

        #expect(visible.contains(try path(of: "payload", in: root)))
        #expect(visible.count == 43, "Every node once: the root, payload, 40 keys and the leaf")
    }
}
