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

    // MARK: - Under a filter

    /// One foreign key and one nested document, the two things a disclosure control opens.
    private func makeFilterRoot() -> JSONRowNode {
        JSONRowNodeBuilder.build(
            columns: ["owner_id", "meta"],
            values: [.text("42"), .text("{\"color\": \"teal\", \"size\": \"xl\"}")],
            columnTypes: [.integer(rawType: "INT"), .json(rawType: "JSON")],
            foreignKeys: ["owner_id": JSONForeignKeyRef(
                column: "owner_id",
                referencedTable: "users",
                referencedSchema: nil,
                referencedColumn: "id"
            )]
        )
    }

    private func fetchedOwner(at path: JSONNodePath) -> JSONRowNode {
        JSONRowNodeBuilder.build(
            path: path,
            key: .name("owner_id"),
            columns: ["id", "email"],
            values: [.text("7"), .text("a@b.c")],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
            foreignKeys: [:]
        )
    }

    private func filteredRows(
        _ root: JSONRowNode,
        query: String,
        expanded: Set<JSONNodePath> = [],
        states: JSONForeignKeyStates = JSONForeignKeyStates(),
        closed: Set<JSONNodePath> = []
    ) throws -> [JSONDisplayRow] {
        let filter = try #require(matcher(query))
        return JSONRowFlattener.rows(
            root: root,
            expanded: expanded,
            states: states,
            visiblePaths: JSONRowFilter.visiblePaths(root: root, fetchedForeignKeys: states.fetched, matcher: filter),
            closedUnderFilter: closed,
            matcher: filter
        )
    }

    @Test("Under a filter a line the reader closed prints collapsed and can be opened again")
    func readerClosesAFilteredLine() throws {
        let root = makeFilterRoot()
        let metaPath = try path(of: "meta", in: root)

        let open = try row(try filteredRows(root, query: "teal"), "meta")
        #expect(open.token == .openObject)
        #expect(open.isExpandable)

        let rows = try filteredRows(root, query: "teal", closed: [metaPath])
        let closed = try row(rows, "meta")
        #expect(closed.token == .collapsedObject(count: 1), "The count is what opening it shows, one match of two keys")
        #expect(closed.isExpanded == false)
        #expect(closed.isExpandable)
        #expect(rows.contains { $0.token == .scalar(.string("teal")) } == false)
    }

    @Test("Under a filter the stored expansion decides nothing")
    func filterIgnoresStoredExpansion() throws {
        let root = makeFilterRoot()
        let metaPath = try path(of: "meta", in: root)
        let everything = try filteredRows(root, query: "teal", expanded: [root.path, metaPath])
        let nothing = try filteredRows(root, query: "teal", expanded: [])
        #expect(everything == nothing)
    }

    /// The fetched row would be filtered out again, so the click would cost a query to show nothing.
    @Test("A foreign key the filter kept for its value offers no control")
    func valueMatchedForeignKeyHasNoControl() throws {
        let root = makeFilterRoot()
        let key = try row(try filteredRows(root, query: "42"), "owner_id")
        #expect(key.token == .scalar(.number("42")))
        #expect(key.isExpandable == false)
    }

    @Test("A foreign key the filter kept for its key keeps its control, and its row is then shown whole")
    func keyMatchedForeignKeyKeepsItsControl() throws {
        let root = makeFilterRoot()
        let keyPath = try path(of: "owner_id", in: root)
        #expect(try row(try filteredRows(root, query: "owner"), "owner_id").isExpandable)

        var states = JSONForeignKeyStates()
        states.fetched[keyPath] = fetchedOwner(at: keyPath)
        let rows = try filteredRows(root, query: "owner", states: states)
        #expect(try row(rows, "owner_id").token == .openObject)
        #expect(rows.contains { $0.key == .name("id") })
        #expect(rows.contains { $0.key == .name("email") })
    }

    @Test("A foreign key inside a document whose key matched keeps its control too")
    func foreignKeyUnderAMatchedAncestorKeepsItsControl() throws {
        let root = makeFilterRoot()
        let keyPath = try path(of: "owner_id", in: root)
        let nestedReference = JSONForeignKeyRef(
            column: "team_id",
            referencedTable: "teams",
            referencedSchema: nil,
            referencedColumn: "id"
        )
        var states = JSONForeignKeyStates()
        states.fetched[keyPath] = JSONRowNodeBuilder.build(
            path: keyPath,
            key: .name("owner_id"),
            columns: ["team_id"],
            values: [.text("3")],
            columnTypes: [.integer(rawType: "INT")],
            foreignKeys: ["team_id": nestedReference]
        )

        #expect(try row(try filteredRows(root, query: "owner", states: states), "team_id").isExpandable)
        #expect(try row(try filteredRows(root, query: "3", states: states), "team_id").isExpandable == false)
    }

    @Test("A fetched foreign key whose row the filter hides offers no control")
    func hiddenFetchedRowHasNoControl() throws {
        let root = makeFilterRoot()
        let keyPath = try path(of: "owner_id", in: root)
        var states = JSONForeignKeyStates()
        states.fetched[keyPath] = fetchedOwner(at: keyPath)

        let key = try row(try filteredRows(root, query: "42", expanded: [root.path, keyPath], states: states), "owner_id")
        #expect(key.token == .scalar(.number("42")))
        #expect(key.isExpandable == false)
    }

    @Test("A fetched foreign key with a field that matches is open, and can be closed")
    func fetchedRowWithAMatchIsOpen() throws {
        let root = makeFilterRoot()
        let keyPath = try path(of: "owner_id", in: root)
        var states = JSONForeignKeyStates()
        states.fetched[keyPath] = fetchedOwner(at: keyPath)

        let open = try filteredRows(root, query: "a@b.c", states: states)
        #expect(try row(open, "owner_id").token == .openObject)
        #expect(open.contains { $0.key == .name("email") })
        #expect(open.contains { $0.key == .name("id") } == false)

        let closed = try row(try filteredRows(root, query: "a@b.c", states: states, closed: [keyPath]), "owner_id")
        #expect(closed.token == .scalar(.number("42")))
        #expect(closed.isExpandable)
    }

    @Test("A plain value and an empty document offer no control, with or without a filter")
    func nothingToOpenOffersNoControl() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["title", "tags"],
            values: [.text("teal"), .text("{}")],
            columnTypes: [.text(rawType: "TEXT"), .json(rawType: "JSON")],
            foreignKeys: [:]
        )
        let unfiltered = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(try row(unfiltered, "title").isExpandable == false)
        #expect(try row(unfiltered, "tags").token == .collapsedObject(count: 0))
        #expect(try row(unfiltered, "tags").isExpandable == false)

        let filtered = try filteredRows(root, query: "t")
        #expect(try row(filtered, "title").isExpandable == false)
        #expect(try row(filtered, "tags").isExpandable == false)
    }

    @Test("Without a filter a foreign key keeps its control whatever its value")
    func unfilteredForeignKeyKeepsItsControl() throws {
        let root = makeFilterRoot()
        let rows = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(try row(rows, "owner_id").isExpandable)
    }

    // MARK: - Decoration

    private func decorationRows(_ columns: [(name: String, value: PluginCellValue, type: ColumnType)]) -> [JSONDisplayRow] {
        let root = JSONRowNodeBuilder.build(
            columns: columns.map { $0.name },
            values: columns.map { $0.value },
            columnTypes: columns.map { $0.type },
            foreignKeys: [:]
        )
        var expanded: Set<JSONNodePath> = [root.path]
        for child in root.children where child.isContainer { expanded.insert(child.path) }
        return JSONRowFlattener.rows(root: root, expanded: expanded, states: JSONForeignKeyStates())
    }

    @Test("A string that is a link or a color says so, and nothing else does")
    func stringValuesAreDecorated() throws {
        let rows = decorationRows([
            (name: "site", value: .text("https://example.com/docs?id=42"), type: .text(rawType: "TEXT")),
            (name: "mail", value: .text("mailto:a@example.com"), type: .text(rawType: "TEXT")),
            (name: "brand", value: .text("#ff8800"), type: .text(rawType: "TEXT")),
            (name: "note", value: .text("see https://example.com for more"), type: .text(rawType: "TEXT")),
            (name: "count", value: .text("255"), type: .integer(rawType: "INT")),
            (name: "blob", value: .bytes(Data("#ff8800".utf8)), type: .blob(rawType: "BLOB")),
            (name: "gone", value: .null, type: .text(rawType: "TEXT")),
        ])

        let site = try #require(URL(string: "https://example.com/docs?id=42"))
        let mail = try #require(URL(string: "mailto:a@example.com"))
        let orange = try #require(CSSColorParser.parse("#ff8800"))
        #expect(try row(rows, "site").decoration == .link(site))
        #expect(try row(rows, "mail").decoration == .link(mail))
        #expect(try row(rows, "brand").decoration == .color(orange))
        for plain in ["note", "count", "blob", "gone"] {
            #expect(try row(rows, plain).decoration == TreeValueDecoration.none, "\(plain)")
        }
    }

    /// The cell stores `https:\/\/example.org\/x` and the line prints its value inside quotes.
    /// Neither is the string the value holds.
    @Test("The decoration is read from the decoded string, not from the printed one")
    func decorationReadsTheDecodedString() throws {
        let rows = decorationRows([
            (
                name: "doc",
                value: .text(##"{"home": "https:\/\/example.org\/x", "tint": "\u0023ff8800", "quoted": "\"#ff8800\""}"##),
                type: .json(rawType: "JSON")
            ),
        ])

        let home = try #require(URL(string: "https://example.org/x"))
        let orange = try #require(CSSColorParser.parse("#ff8800"))
        #expect(try row(rows, "home").decoration == .link(home))
        #expect(try row(rows, "tint").decoration == .color(orange))
        #expect(try row(rows, "quoted").token == .scalar(.string("\"#ff8800\"")))
        #expect(try row(rows, "quoted").decoration == TreeValueDecoration.none)
    }

    @Test("A key is never decorated, only the value beside it")
    func keysAreNotDecorated() throws {
        let rows = decorationRows([
            (name: "https://example.com", value: .text("plain"), type: .text(rawType: "TEXT")),
            (name: "#ff8800", value: .text("{\"#00ff00\": 1}"), type: .json(rawType: "JSON")),
        ])
        #expect(rows.allSatisfy { $0.decoration == TreeValueDecoration.none })
    }

    @Test("A value past the link cap is plain text, however it starts")
    func longValuesAreNotClassified() throws {
        let long = "https://example.com/" + String(repeating: "a", count: 1_000_000)
        let rows = decorationRows([(name: "body", value: .text(long), type: .text(rawType: "TEXT"))])
        #expect(try row(rows, "body").decoration == TreeValueDecoration.none)
    }

    /// The line of an opened foreign key draws a brace, so there is no value on it to decorate,
    /// while the value it was opened from is still there for Copy Value.
    @Test("A foreign key holding a link is one while closed, and not on the line that opened it")
    func openedForeignKeyIsNotDecorated() throws {
        let link = "https://example.com/users/7"
        let root = JSONRowNodeBuilder.build(
            columns: ["profile"],
            values: [.text(link)],
            columnTypes: [.text(rawType: "TEXT")],
            foreignKeys: ["profile": reference]
        )
        let keyPath = try path(of: "profile", in: root)
        let url = try #require(URL(string: link))
        let closed = JSONRowFlattener.rows(root: root, expanded: [root.path], states: JSONForeignKeyStates())
        #expect(try row(closed, "profile").decoration == .link(url))

        var states = JSONForeignKeyStates()
        states.fetched[keyPath] = JSONRowNodeBuilder.build(
            path: keyPath,
            key: .name("profile"),
            columns: ["name"],
            values: [.text("English")],
            columnTypes: [.text(rawType: "CHAR")],
            foreignKeys: [:]
        )
        let opened = JSONRowFlattener.rows(root: root, expanded: [root.path, keyPath], states: states)
        let line = try #require(opened.first { $0.path == keyPath && $0.token == .openObject })
        #expect(line.scalar == .string(link))
        #expect(line.decoration == TreeValueDecoration.none)
    }
}
