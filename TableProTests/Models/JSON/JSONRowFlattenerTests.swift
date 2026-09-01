//
//  JSONRowFlattenerTests.swift
//  TableProTests
//
//  The printed lines: braces, commas, disclosure state and foreign key status.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("JSONRowFlattener")
struct JSONRowFlattenerTests {
    private let reference = JSONForeignKeyRef(
        column: "language_id",
        referencedTable: "language",
        referencedSchema: nil,
        referencedColumn: "language_id"
    )

    private func makeRoot(foreignKeys: [String: JSONForeignKeyRef] = [:]) -> JSONRowNode {
        JSONRowNodeBuilder.build(
            columns: ["film_id", "language_id"],
            values: [.text("2"), .text("1")],
            columnTypes: [.integer(rawType: "INT"), .integer(rawType: "INT")],
            foreignKeys: foreignKeys
        )
    }

    private func row(_ rows: [JSONDisplayRow], _ column: String) throws -> JSONDisplayRow {
        try #require(rows.first { $0.key == .name(column) && $0.token != .closeObject })
    }

    /// A column's path carries its position, so a test asks the tree for it.
    private func path(of column: String, in root: JSONRowNode) throws -> JSONNodePath {
        try #require(root.children.first { $0.key == .name(column) }).path
    }

    @Test("An expanded root prints its braces around its keys")
    func printsBraces() {
        let root = makeRoot()
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(rows.count == 4)
        #expect(rows.first?.token == .openObject)
        #expect(rows.last?.token == .closeObject)
        #expect(rows.last?.depth == 0)
    }

    @Test("Every key but the last carries a comma")
    func printsCommas() throws {
        let root = makeRoot()
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(try row(rows, "film_id").needsComma)
        #expect(try row(rows, "language_id").needsComma == false)
    }

    @Test("A collapsed root prints one line with its key count")
    func printsCollapsedRoot() {
        let root = makeRoot()
        let rows = JSONRowFlattener.rows(root: root, expanded: [], states: JSONForeignKeyStates())
        #expect(rows.count == 1)
        #expect(rows.first?.token == .collapsedObject(count: 2))
        #expect(rows.first?.isExpandable == true)
    }

    @Test("An unexpanded foreign key prints its value and offers a control")
    func printsUnexpandedForeignKey() throws {
        let root = makeRoot(foreignKeys: ["language_id": reference])
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        let key = try row(rows, "language_id")
        #expect(key.token == .scalar(.number("1")))
        #expect(key.isExpandable)
        #expect(key.foreignKey == reference)
    }

    @Test("A NULL foreign key offers no control")
    func offersNoControlForNullKeys() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["original_language_id"],
            values: [.null],
            columnTypes: [.integer(rawType: "INT")],
            foreignKeys: [
                "original_language_id": JSONForeignKeyRef(
                    column: "original_language_id",
                    referencedTable: "language",
                    referencedSchema: nil,
                    referencedColumn: "language_id"
                ),
            ]
        )
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(try row(rows, "original_language_id").isExpandable == false)
    }

    @Test("A fetched foreign key prints the row it references")
    func printsFetchedForeignKey() throws {
        let root = makeRoot(foreignKeys: ["language_id": reference])
        let keyPath = try path(of: "language_id", in: root)
        var states = JSONForeignKeyStates()
        states.fetched[keyPath] = JSONRowNodeBuilder.build(
            path: keyPath,
            key: .name("language_id"),
            columns: ["name"],
            values: [.text("English")],
            columnTypes: [.text(rawType: "CHAR")],
            foreignKeys: [:]
        )

        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path, keyPath], states: states)
        #expect(try row(rows, "language_id").token == .openObject)
        let nestedPath = try #require(states.fetched[keyPath]?.children.first).path
        let nested = try #require(rows.first { $0.path == nestedPath })
        #expect(nested.token == .scalar(.string("English")))
        #expect(nested.depth == 2)
    }

    @Test("A key being fetched reports as loading")
    func reportsLoading() throws {
        let root = makeRoot(foreignKeys: ["language_id": reference])
        var states = JSONForeignKeyStates()
        states.loading.insert(try path(of: "language_id", in: root))
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: states)
        #expect(try row(rows, "language_id").status == .loading)
    }

    @Test("A key that could not be followed reports why")
    func reportsFailure() throws {
        let root = makeRoot(foreignKeys: ["language_id": reference])
        var states = JSONForeignKeyStates()
        states.failures[try path(of: "language_id", in: root)] = .cycle
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: states)
        #expect(try row(rows, "language_id").status == .failure(.cycle))
    }

    @Test("A filter expands what it kept, whatever was collapsed before")
    func filterExpandsMatches() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["payload"],
            values: [.text("{\"inner\": \"found\"}")],
            columnTypes: [.json(rawType: "JSON")],
            foreignKeys: [:]
        )
        let visible = JSONRowFilter.visiblePaths(
            root: root,
            fetchedForeignKeys: [:],
            matcher: try #require(matcher("found"))
        )
        let rows = JSONRowFlattener.rows(root: root, expanded: [], states: JSONForeignKeyStates(), visiblePaths: visible)
        #expect(rows.contains { $0.token == .scalar(.string("found")) })
        #expect(rows.first?.token == .openObject)
    }

    @Test("Expand All names every container, and no unfetched foreign key")
    func expandAllSkipsUnfetchedKeys() {
        let root = makeRoot(foreignKeys: ["language_id": reference])
        let paths = JSONRowFlattener.expandablePaths(root: root, states: JSONForeignKeyStates())
        #expect(paths == [root.path])
    }

    private func matcher(_ query: String) -> JSONRowMatcher? {
        guard case .matcher(let matcher) = JSONRowMatcher.make(query: query) else { return nil }
        return matcher
    }

    /// An expanded foreign key draws as `{`, and reading its value out of the token alone took
    /// Copy Value and Open off the line the moment the reader opened it.
    @Test("An expanded foreign key line still carries the value it was opened from")
    func expandedForeignKeyKeepsItsScalar() throws {
        let root = makeRoot(foreignKeys: ["language_id": reference])
        let keyPath = try path(of: "language_id", in: root)
        var states = JSONForeignKeyStates()
        states.fetched[keyPath] = JSONRowNodeBuilder.build(
            path: keyPath,
            key: .name("language_id"),
            columns: ["name"],
            values: [.text("English")],
            columnTypes: [.text(rawType: "CHAR")],
            foreignKeys: [:]
        )

        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path, keyPath], states: states)
        let opened = try #require(rows.first { $0.path == keyPath && $0.token == .openObject })
        #expect(opened.scalar == .number("1"))
        #expect(opened.foreignKey == reference)
    }

    @Test("A collapsed foreign key carries the same value the expanded one does")
    func collapsedForeignKeyCarriesItsScalar() throws {
        let root = makeRoot(foreignKeys: ["language_id": reference])
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(try row(rows, "language_id").scalar == .number("1"))
    }
}
