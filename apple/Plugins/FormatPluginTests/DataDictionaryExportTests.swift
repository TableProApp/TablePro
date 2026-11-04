//
//  DataDictionaryExportTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

private final class CatalogOnlyDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    var columns: [String: [PluginColumnInfo]] = [:]
    var indexes: [String: [PluginIndexInfo]] = [:]
    var foreignKeys: [String: [PluginForeignKeyInfo]] = [:]
    var comments: [String: String] = [:]
    var failingColumns: Set<String> = []
    var failingIndexes: Set<String> = []
    var onColumnRead: ((String) -> Void)?
    private(set) var rowReads = 0
    private(set) var indexReads: [String] = []
    private(set) var foreignKeyReads: [String] = []

    init(databaseTypeId: String = "PostgreSQL") {
        self.databaseTypeId = databaseTypeId
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        rowReads += 1
        return AsyncThrowingStream { $0.finish() }
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        rowReads += 1
        return nil
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        rowReads += 1
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }

    func escapeStringLiteral(_ value: String) -> String { value }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        onColumnRead?(table)
        if failingColumns.contains(table) { throw StubError.denied }
        return columns[table] ?? []
    }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        indexReads.append(table)
        if failingIndexes.contains(table) { throw StubError.denied }
        return indexes[table] ?? []
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        foreignKeyReads.append(table)
        return foreignKeys[table] ?? []
    }

    func fetchObjectComment(_ object: PluginExportTable) async throws -> String? {
        comments[object.name]
    }
}

private enum StubError: LocalizedError {
    case denied

    var errorDescription: String? { "permission denied" }
}

private func object(_ name: String, kind: PluginExportObjectKind = .table, schema: String = "public") -> PluginExportTable {
    PluginExportTable(name: name, databaseName: "", tableType: kind.rawValue, schema: schema, kind: kind)
}

private func shopSource() -> CatalogOnlyDataSource {
    let source = CatalogOnlyDataSource()
    source.columns = [
        "orgs": [
            PluginColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true,
                             defaultValue: "nextval('orgs_id_seq'::regclass)"),
            PluginColumnInfo(name: "name", dataType: "text", isNullable: false, comment: "Shown on invoices")
        ],
        "users": [
            PluginColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "org_id", dataType: "integer", isNullable: true)
        ],
        "active_users": [
            PluginColumnInfo(name: "id", dataType: "bigint", isNullable: true)
        ]
    ]
    source.indexes = [
        "users": [
            PluginIndexInfo(name: "users_pkey", columns: ["id"], isUnique: true, isPrimary: true, type: "btree"),
            PluginIndexInfo(name: "users_org_idx", columns: ["org_id"], type: "btree", whereClause: "org_id IS NOT NULL")
        ]
    ]
    source.foreignKeys = [
        "users": [
            PluginForeignKeyInfo(name: "users_org_fk", column: "org_id", referencedTable: "orgs",
                                 referencedColumn: "id", referencedDatabase: nil, referencedSchema: "public",
                                 onDelete: "CASCADE")
        ]
    ]
    source.comments = ["orgs": "Companies that own accounts"]
    return source
}

private func readDocument(
    _ tables: [PluginExportTable],
    from source: CatalogOnlyDataSource
) async throws -> (DataDictionaryDocument, DataDictionaryReadFailures) {
    var failures = DataDictionaryReadFailures()
    var objects: [DataDictionaryObject] = []
    let progress = PluginExportProgress(progress: Progress(totalUnitCount: 0))
    for table in tables {
        objects.append(try await DataDictionaryReader.read(table, from: source, progress: progress, failures: &failures))
    }
    let document = DataDictionaryDocument(
        title: "shop",
        databaseTypeId: source.databaseTypeId,
        generatedAt: Date(timeIntervalSince1970: 0),
        objects: objects
    )
    return (document, failures)
}

struct DataDictionaryExportTests {
    @Test("The plugin reads no rows and names its file after the chosen output")
    func readsNoRows() {
        let plugin = DataDictionaryExportPlugin()
        for kind in DataDictionaryExportPlugin.supportedObjectKinds {
            #expect(!plugin.readsRows(optionValues: [], kind: kind))
        }
        #expect(Set(DataDictionaryExportPlugin.excludedDatabaseTypeIds) == ["DynamoDB", "SurrealDB"])
        #expect(DataDictionaryFileType.markdown.fileExtension == "md")
        #expect(DataDictionaryFileType.html.fileExtension == "html")
    }

    @Test("A schema is read from the catalog only: columns, indexes, keys and comments, never a row")
    func readsTheCatalogOnly() async throws {
        let source = shopSource()
        let (document, failures) = try await readDocument(
            [object("orgs"), object("users"), object("active_users", kind: .view)], from: source)

        #expect(source.rowReads == 0)
        #expect(failures.warnings.isEmpty)
        #expect(source.indexReads == ["orgs", "users", "active_users"])
        #expect(source.foreignKeyReads == ["orgs", "users"])
        #expect(document.objects.map { $0.columns.count } == [2, 2, 1])
        #expect(document.objects[0].comment == "Companies that own accounts")
    }

    @Test("Markdown lists every object in a table of contents that links to its anchor")
    func markdownContents() async throws {
        let (document, _) = try await readDocument(
            [object("orgs"), object("users"), object("active_users", kind: .view)], from: shopSource())
        let markdown = DataDictionaryMarkdownRenderer.render(document)

        #expect(markdown.hasPrefix("# shop\n\nData dictionary generated "))
        #expect(markdown.contains(" from PostgreSQL: 2 tables, 1 view.\n"))
        #expect(markdown.contains("- [`orgs`](#orgs)\n- [`users`](#users)\n- [`active_users`](#active_users) (view)"))
        #expect(markdown.contains("<a id=\"users\"></a>\n\n## `users`\n\n**Table.**"))
        #expect(markdown.contains("**Table.** Companies that own accounts"))
        #expect(markdown.contains("**View.**"))
    }

    @Test("Each column row carries its type, nullability, default, key, reference and comment")
    func markdownColumns() async throws {
        let (document, _) = try await readDocument([object("orgs"), object("users")], from: shopSource())
        let markdown = DataDictionaryMarkdownRenderer.render(document)

        #expect(markdown.contains("| Column | Type | Nullable | Default | Key | References | Comment |"))
        #expect(markdown.contains(
            "| `id` | `integer` | No | `nextval('orgs_id_seq'::regclass)` | PK |  |  |"))
        #expect(markdown.contains("| `name` | `text` | No |  |  |  | Shown on invoices |"))
        #expect(markdown.contains("| `org_id` | `integer` | Yes |  |  | [`orgs.id`](#orgs) |  |"))
        #expect(markdown.contains("| `users_org_idx` | `org_id WHERE org_id IS NOT NULL` | Index | btree |"))
        #expect(markdown.contains("| `users_pkey` | `id` | Primary key | btree |"))
        #expect(markdown.contains("| `users_org_fk` | `org_id` | [`orgs`](#orgs) (`id`) | CASCADE | NO ACTION |"))
    }

    @Test("Columns nothing in the document fills are left out rather than printed empty")
    func emptyColumnsAreLeftOut() async throws {
        let source = CatalogOnlyDataSource(databaseTypeId: "SQLite")
        source.columns = ["notes": [PluginColumnInfo(name: "body", dataType: "TEXT")]]
        let (document, _) = try await readDocument([object("notes", schema: "main")], from: source)
        let markdown = DataDictionaryMarkdownRenderer.render(document)
        let html = DataDictionaryHTMLRenderer.render(document)

        #expect(markdown.contains("| Column | Type | Nullable |\n| --- | --- | --- |\n| `body` | `TEXT` | Yes |"))
        #expect(!markdown.contains("### Indexes"))
        #expect(!markdown.contains("### Foreign keys"))
        #expect(html.contains("<th>Column</th><th>Type</th><th>Nullable</th></tr>"))
    }

    @Test("A pipe, a backtick, a line break and markup in metadata cannot break the Markdown table")
    func markdownEscaping() async throws {
        let source = CatalogOnlyDataSource()
        source.columns = ["t": [
            PluginColumnInfo(name: "a|b", dataType: "text", defaultValue: "'x`y'", comment: "first line\nsecond | *bold* <b>")
        ]]
        let (document, _) = try await readDocument([object("t")], from: source)
        let markdown = DataDictionaryMarkdownRenderer.render(document)

        #expect(markdown.contains("| `a\\|b` | `text` | Yes | ``'x`y'`` | first line second \\| \\*bold\\* \\<b\\> |"))
    }

    @Test("A composite foreign key is one row, and a key into another schema names that schema")
    func compositeAndCrossSchemaKeys() async throws {
        let source = CatalogOnlyDataSource()
        source.columns = ["lines": [
            PluginColumnInfo(name: "order_id", dataType: "integer"),
            PluginColumnInfo(name: "line_no", dataType: "integer")
        ]]
        source.foreignKeys = ["lines": [
            PluginForeignKeyInfo(name: "lines_fk", column: "order_id", referencedTable: "orders",
                                 referencedColumn: "id", referencedDatabase: nil, referencedSchema: "sales"),
            PluginForeignKeyInfo(name: "lines_fk", column: "line_no", referencedTable: "orders",
                                 referencedColumn: "line", referencedDatabase: nil, referencedSchema: "sales")
        ]]
        let (document, _) = try await readDocument([object("lines")], from: source)
        let rows = document.foreignKeyRows(at: 0)

        #expect(rows.count == 1)
        #expect(rows.first?.columns == ["order_id", "line_no"])
        #expect(rows.first?.referencedColumns == ["id", "line"])
        #expect(rows.first?.target.text == "sales.orders")
        #expect(rows.first?.target.anchor == nil)
    }

    @Test("Objects from two schemas are named with their schema, and every anchor is unique")
    func qualifiedNamesAndUniqueAnchors() async throws {
        let source = CatalogOnlyDataSource()
        source.columns = ["users": [PluginColumnInfo(name: "id", dataType: "int")]]
        let (document, _) = try await readDocument(
            [object("users", schema: "public"), object("users", schema: "audit")], from: source)
        let markdown = DataDictionaryMarkdownRenderer.render(document)

        #expect(document.anchors == ["public-users", "audit-users"])
        #expect(markdown.contains("## `public.users`"))
        #expect(markdown.contains("## `audit.users`"))
        #expect(DataDictionaryAnchors.make(for: ["Order Items", "order-items", "contents", "!!"])
            == ["order-items", "order-items-2", "contents-2", "object"])
    }

    @Test("The HTML file is self-contained, escaped and prints with repeated table headers")
    func htmlIsSelfContained() async throws {
        let source = shopSource()
        source.comments["users"] = "<script>alert(1)</script> & co"
        let (document, _) = try await readDocument([object("orgs"), object("users")], from: source)
        let html = DataDictionaryHTMLRenderer.render(document)

        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<link"))
        #expect(!html.contains("src="))
        #expect(!html.contains("https://"))
        #expect(!html.contains("http://"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; co"))
        #expect(html.contains("<li><a href=\"#users\"><code>users</code></a></li>"))
        #expect(html.contains("<section id=\"users\">"))
        #expect(html.contains("<a href=\"#orgs\"><code>orgs.id</code></a>"))
        #expect(html.contains("@media print"))
        #expect(html.contains("thead { display: table-header-group; }"))
    }

    @Test("HTML escapes syntax inside grapheme clusters", arguments: ["\u{0D4E}", "\u{0600}"])
    func htmlEscapesScalars(prepend: String) {
        let entities = [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&#39;")]
        for (symbol, entity) in entities {
            #expect(DataDictionaryHTMLRenderer.escape(prepend + symbol) == prepend + entity)
            #expect(DataDictionaryHTMLRenderer.escape(symbol + "\u{0301}") == entity + "\u{0301}")
        }
        let unicode = "café e\u{0301} 日本語 👩🏽‍💻"
        #expect(DataDictionaryHTMLRenderer.escape(unicode).unicodeScalars.elementsEqual(unicode.unicodeScalars))
    }

    @Test("Markdown escapes syntax inside grapheme clusters", arguments: ["\u{0D4E}", "\u{0600}"])
    func markdownEscapesScalars(prepend: String) {
        for scalar in "\\`*_[]<>#&|".unicodeScalars {
            let symbol = String(scalar)
            #expect(DataDictionaryMarkdownRenderer.text(prepend + symbol, inTable: true) == prepend + "\\" + symbol)
            #expect(DataDictionaryMarkdownRenderer.text(symbol + "\u{0301}", inTable: true) == "\\" + symbol + "\u{0301}")
        }
    }

    @Test("Markdown code fences count scalar backticks", arguments: ["\u{0D4E}", "\u{0600}"])
    func markdownCodeScalars(prepend: String) {
        #expect(DataDictionaryMarkdownRenderer.code(prepend + "`x") == "``" + prepend + "`x``")
        #expect(DataDictionaryMarkdownRenderer.code(prepend + "`") == "`` " + prepend + "` ``")
        #expect(DataDictionaryMarkdownRenderer.code("`\u{0301}x") == "`` `\u{0301}x ``")
        #expect(DataDictionaryMarkdownRenderer.code(prepend + "``\u{0301}x") == "```" + prepend + "``\u{0301}x```")
        #expect(DataDictionaryMarkdownRenderer.code(prepend + "|\u{0301}", inTable: true) == "`" + prepend + "\\|\u{0301}`")
        #expect(DataDictionaryMarkdownRenderer.code(" x ") == "`  x  `")
        #expect(DataDictionaryMarkdownRenderer.code("   ") == "`   `")
    }

    @Test("Anchors exclude markup joined to letters", arguments: ["\u{0D4E}", "\u{0600}"])
    func anchorsExcludeSyntax(prepend: String) {
        let names = ["&", "<", ">", "\"", "'", "`", "[", "]", "(", ")", "|", " "].map { "table" + prepend + $0 + "name" }
        let anchors = DataDictionaryAnchors.make(for: names)
        #expect(Set(anchors).count == names.count)
        for anchor in anchors {
            #expect(!anchor.unicodeScalars.contains { "&<>\"'`[]()| ".unicodeScalars.contains($0) })
        }
        #expect(DataDictionaryAnchors.slug("日本語_123") == "日本語_123")
    }

    @Test("Catalog markup stays text in both exports", arguments: ["\u{0D4E}", "\u{0600}"])
    func catalogMarkupStaysText(prepend: String) async throws {
        let payload = prepend + "<img src=x onerror=alert(1) " + prepend + ">"
        let name = "table" + prepend + "\"" + prepend + ">" + payload
        let source = CatalogOnlyDataSource()
        source.comments[name] = payload
        source.columns[name] = [PluginColumnInfo(name: payload, dataType: payload, defaultValue: payload, comment: payload)]
        let (document, _) = try await readDocument([object(name)], from: source)
        let html = DataDictionaryHTMLRenderer.render(document)
        let markdown = DataDictionaryMarkdownRenderer.render(document)
        let escaped = prepend + "&lt;img src=x onerror=alert(1) " + prepend + "&gt;"
        #expect(!html.contains("<img"))
        #expect(html.contains("<td>\(escaped)</td>"))
        #expect(html.contains("<code>\(escaped)</code>"))
        #expect(html.contains("Table.</span> \(escaped)</p>"))
        #expect(html.contains("<section id=\"\(document.anchors[0])\">"))
        #expect(html.contains("href=\"#\(document.anchors[0])\""))
        #expect(markdown.contains("**Table.** " + prepend + "\\<img src=x onerror=alert(1) " + prepend + "\\>"))
        #expect(markdown.contains("<a id=\"\(document.anchors[0])\"></a>"))
    }

    @Test("HTML blocks active content before rendering catalog values")
    func htmlContentSecurityPolicy() async throws {
        let (document, _) = try await readDocument([object("users")], from: shopSource())
        let html = DataDictionaryHTMLRenderer.render(document)
        let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">"#
        let policyRange = try #require(html.range(of: policy))
        let titleRange = try #require(html.range(of: "<title>"))
        let styleRange = try #require(html.range(of: "<style>"))
        #expect(policyRange.lowerBound < titleRange.lowerBound)
        #expect(policyRange.lowerBound < styleRange.lowerBound)
    }

    @Test("A read that fails is named in the file and in the warnings, and the export goes on")
    func failedReadsAreReported() async throws {
        let source = shopSource()
        source.failingColumns = ["orgs"]
        source.failingIndexes = ["users"]
        let (document, failures) = try await readDocument([object("orgs"), object("users")], from: source)
        let markdown = DataDictionaryMarkdownRenderer.render(document)

        #expect(markdown.contains("Columns could not be read: permission denied"))
        #expect(markdown.contains("### Indexes\n\nIndexes could not be read: permission denied"))
        #expect(failures.columns == ["orgs"])
        #expect(failures.indexes.count == 1)
        #expect(failures.warnings.count == 2)
        #expect(document.objects[1].columns.count == 2)
    }

    @Test("An index on a column prefix names the prefix length")
    func indexPrefixLengths() async throws {
        let source = CatalogOnlyDataSource(databaseTypeId: "MySQL")
        source.columns = ["users": [PluginColumnInfo(name: "email", dataType: "varchar(255)")]]
        source.indexes = ["users": [
            PluginIndexInfo(name: "uq_email", columns: ["email"], isUnique: true, columnPrefixes: ["email": 10])
        ]]
        let (document, _) = try await readDocument([object("users", schema: "shop")], from: source)

        #expect(document.indexRows(at: 0).first?.columns == "email(10)")
    }

    @Test("Generated, identity and auto-increment columns say how their value is made")
    func derivedDefaults() {
        let generated = PluginColumnInfo(
            name: "total", dataType: "numeric", generationExpression: "price * qty", generationKind: .stored)
        let identity = PluginColumnInfo(name: "id", dataType: "bigint", identityKind: .always)
        let autoIncrement = PluginColumnInfo(name: "id", dataType: "int", extra: "auto_increment", identityKind: .byDefault)

        #expect(DataDictionaryDocument.defaultText(of: generated) == "GENERATED ALWAYS AS (price * qty) STORED")
        #expect(DataDictionaryDocument.defaultText(of: identity) == "GENERATED ALWAYS AS IDENTITY")
        #expect(DataDictionaryDocument.defaultText(of: autoIncrement) == "AUTO_INCREMENT")
    }

    @Test("Stopping the export ends it between objects")
    func cancellationStops() async throws {
        let source = shopSource()
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 0))
        source.onColumnRead = { table in
            if table == "orgs" { progress.cancel() }
        }
        let plugin = DataDictionaryExportPlugin()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: PluginExportCancellationError.self) {
            _ = try await plugin.export(
                tables: [object("orgs"), object("users")],
                dataSource: source,
                destination: destination,
                progress: progress
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }
}
