//
//  ExportImportRoundTripTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

// Each format's own export plugin writes a SQLite table to a file, and its own import plugin reads
// the file back into an empty database. Every row has to come back as it was, except for what the
// format has no way to carry.
@Suite(.serialized)
struct ExportImportRoundTripTests {
    // MARK: - SQL

    @Test("A SQL dump restores every value exactly", arguments: SQLExportInsertMode.allCases)
    func sqlRestoresEveryValue(mode: SQLExportInsertMode) async throws {
        var options = SQLExportOptions()
        options.insertMode = mode
        options.batchSize = 7
        let source = try RoundTripFixture.database()

        let dump = try await RoundTrip.sqlDump(of: [RoundTripFixture.table], from: source, options: options)
        defer { RoundTrip.remove(dump.files) }
        let target = try RoundTripDatabase()
        try await RoundTrip.restore(dump.files, into: target)

        try RoundTrip.expectSame(target, RoundTripFixture.table, RoundTripFixture.rows)
    }

    @Test("A gzipped SQL dump decompresses to the whole dump and restores every row")
    func gzippedSQLRestoresEveryRow() async throws {
        let source = try RoundTripFixture.databaseWithBulk()
        let tables = [RoundTripFixture.table, RoundTripFixture.bulkTable]
        var compressed = SQLExportOptions()
        compressed.compressWithGzip = true

        let plain = try await RoundTrip.sqlDump(of: tables, from: source, options: SQLExportOptions())
        let gzipped = try await RoundTrip.sqlDump(of: tables, from: source, options: compressed, fileExtension: "sql.gz")
        defer { RoundTrip.remove(plain.files + gzipped.files) }

        let file = try #require(gzipped.files.first)
        let plainFile = try #require(plain.files.first)
        #expect(gzipped.files.count == 1)
        #expect(try Data(contentsOf: file).prefix(2) == Data([0x1F, 0x8B]))
        let decompressed = RoundTrip.withoutTimestamp(try RoundTripImportFile.text(of: file))
        let uncompressed = RoundTrip.withoutTimestamp(try RoundTripImportFile.text(of: plainFile))
        #expect(decompressed == uncompressed)

        let target = try RoundTripDatabase()
        try await RoundTrip.restore(gzipped.files, into: target)
        try RoundTrip.expectSame(target, RoundTripFixture.table, RoundTripFixture.rows)
        try RoundTrip.expectSame(target, RoundTripFixture.bulkTable, RoundTripFixture.bulkRows)
    }

    @Test("A SQL dump split into parts restores every row when the parts run in order")
    func splitSQLRestoresInPartOrder() async throws {
        let source = try RoundTripFixture.databaseWithBulk()
        var options = SQLExportOptions()
        options.splitSizeMegabytes = 1

        let dump = try await RoundTrip.sqlDump(
            of: [RoundTripFixture.table, RoundTripFixture.bulkTable], from: source, options: options)
        defer { RoundTrip.remove(dump.files) }
        #expect(dump.files.count >= 3)

        let target = try RoundTripDatabase()
        try await RoundTrip.restore(dump.files, into: target)
        try RoundTrip.expectSame(target, RoundTripFixture.table, RoundTripFixture.rows)
        try RoundTrip.expectSame(target, RoundTripFixture.bulkTable, RoundTripFixture.bulkRows)
    }

    // MARK: - CSV

    @Test(
        "A CSV file imports back with only CSV's own limits",
        arguments: CSVLineBreak.allCases, CSVDelimiter.allCases
    )
    func csvImportsBack(lineBreak: CSVLineBreak, delimiter: CSVDelimiter) async throws {
        var options = CSVExportOptions()
        options.lineBreak = lineBreak
        options.delimiter = delimiter
        let target = try await RoundTrip.csv(options)
        try RoundTrip.expectSame(target, RoundTripFixture.table, FormatLimits.csv.carried(RoundTripFixture.rows))
    }

    @Test("A CSV file written with a byte order mark imports back")
    func csvWithByteOrderMarkImportsBack() async throws {
        var options = CSVExportOptions()
        options.writesByteOrderMark = true
        let target = try await RoundTrip.csv(options)
        try RoundTrip.expectSame(target, RoundTripFixture.table, FormatLimits.csv.carried(RoundTripFixture.rows))
    }

    @Test("Every value but a binary one comes back from CSV written with NULL spelled out and formulas left alone")
    func csvWithNullTextImportsBack() async throws {
        var export = CSVExportOptions()
        export.convertNullToEmpty = false
        export.sanitizeFormulas = false
        var importing = CSVImportOptions()
        importing.emptyAsNull = false
        importing.nullString = "NULL"
        let target = try await RoundTrip.csv(export, importing: importing)

        let limits = FormatLimits(binary: { .text(FormatLimits.hex($0)) })
        let expected = limits.carried(RoundTripFixture.rows).map { row in
            row.map { $0 == .text("NULL") ? StoredValue.null : $0 }
        }
        try RoundTrip.expectSame(target, RoundTripFixture.table, expected)
    }

    // MARK: - JSON

    @Test(
        "A JSON file imports back with only JSON's own limits",
        arguments: JSONExportLayout.allCases, [true, false]
    )
    func jsonImportsBack(layout: JSONExportLayout, prettyPrint: Bool) async throws {
        var options = JSONExportOptions()
        options.layout = layout
        options.prettyPrint = prettyPrint
        let target = try await RoundTrip.json(options)
        try RoundTrip.expectSame(target, RoundTripFixture.table, FormatLimits.json.carried(RoundTripFixture.rows))
    }

    @Test("A JSON file that leaves out null values imports them back as NULL")
    func jsonWithoutNullsImportsBack() async throws {
        var options = JSONExportOptions()
        options.includeNullValues = false
        let target = try await RoundTrip.json(options)
        try RoundTrip.expectSame(target, RoundTripFixture.table, FormatLimits.json.carried(RoundTripFixture.rows))
    }

    @Test("A JSON file with every value written as a string imports back")
    func jsonWithStringsImportsBack() async throws {
        var options = JSONExportOptions()
        options.preserveAllAsStrings = true
        let target = try await RoundTrip.json(options)
        try RoundTrip.expectSame(target, RoundTripFixture.table, FormatLimits.json.carried(RoundTripFixture.rows))
    }

    @Test("JSON writes true and false bare only in a boolean column")
    func jsonBooleansFollowTheColumnType() async throws {
        var options = JSONExportOptions()
        options.layout = .newlineDelimited
        let source = TypedRowSource(
            columns: ["pg", "clickhouse", "label", "untyped"],
            columnTypeNames: ["bool", "Nullable(Bool)", "text", ""],
            rows: [["true", "FALSE", "TRUE", "true"]]
        )
        let file = try await RoundTrip.exportFile(JSONExportPlugin(), settings: options, from: source, fileExtension: "ndjson")
        defer { RoundTrip.remove([file]) }
        #expect(try String(contentsOf: file, encoding: .utf8)
            == #"{"pg": true, "clickhouse": false, "label": "TRUE", "untyped": "true"}"# + "\n")
    }

    // MARK: - XLSX

    @Test("An XLSX workbook imports back with only XLSX's own limits")
    func xlsxImportsBack() async throws {
        let target = try await RoundTrip.xlsx(XLSXExportOptions())
        try RoundTrip.expectSame(target, RoundTripFixture.table, FormatLimits.xlsx.carried(RoundTripFixture.rows))
    }
}

extension FormatLimits {
    // CSV has no NULL and no binary: both NULL and '' are written as an empty field and read as
    // NULL, and a binary value is written as hex text. A value a spreadsheet would run as a
    // formula gains a leading quote.
    static let csv = FormatLimits(
        emptyTextIsNull: true,
        binary: { .text(FormatLimits.hex($0)) },
        text: { FormatLimits.csvNeutralised[$0] ?? $0 }
    )

    static let csvNeutralised: [String: String] = [
        "=1+1": "'=1+1",
        "@SUM(A1)": "'@SUM(A1)",
        "-- not a comment": "'-- not a comment",
    ]

    // JSON has no binary type: a binary value is written as base64 text.
    static let json = FormatLimits(binary: { .text($0.base64EncodedString()) })

    // An empty cell is not written, so '' reads back as NULL; a binary value is written as hex text,
    // and XML 1.0 cannot hold a control character other than tab and the two line breaks.
    static let xlsx = FormatLimits(
        emptyTextIsNull: true,
        binary: { $0.isEmpty ? .null : .text(FormatLimits.hex($0)) },
        text: { text in
            String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
                scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" || scalar == "\r"
            }))
        }
    )
}

enum RoundTrip {
    static func temporaryURL(_ name: String = UUID().uuidString, fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundTrip-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(name).\(fileExtension)")
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func remove(_ urls: [URL]) {
        for directory in Set(urls.map { $0.deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func withoutTimestamp(_ dump: String) -> String {
        dump.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("-- Generated:") }
            .joined(separator: "\n")
    }

    static func expectSame(
        _ database: RoundTripDatabase,
        _ table: String,
        _ expected: [[StoredValue]],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let imported = try database.storedRows(of: table)
        #expect(imported.count == expected.count, "row count", sourceLocation: sourceLocation)
        for (index, pair) in zip(imported, expected).enumerated() where pair.0 != pair.1 {
            Issue.record("\(table) row \(index + 1): imported \(pair.0), expected \(pair.1)", sourceLocation: sourceLocation)
        }
    }

    // MARK: SQL

    static func sqlDump(
        of tables: [String],
        from database: RoundTripDatabase,
        options: sending SQLExportOptions,
        fileExtension: String = "sql"
    ) async throws -> (files: [URL], result: ExportFormatResult) {
        let written = try await SQLExportHarness.shared.partData(
            tables: tables.map { RoundTripFixture.exportTable($0, optionValues: [true, true, true]) },
            dataSource: SQLiteExportSource(database),
            options: options
        )
        let directory = temporaryURL(fileExtension: fileExtension).deletingLastPathComponent()
        let urls = written.parts.count == 1
            ? [directory.appendingPathComponent("dump.\(fileExtension)")]
            : written.parts.indices.map { directory.appendingPathComponent("dump.part\($0 + 1).\(fileExtension)") }
        for (url, data) in zip(urls, written.parts) {
            try write(data, to: url)
        }
        return (urls, written.result)
    }

    static func restore(_ files: [URL], into database: RoundTripDatabase) async throws {
        let plugin = SQLImportPlugin()
        let stored = plugin.settings
        plugin.settings = SQLImportOptions()
        defer { plugin.settings = stored }
        let result = try await plugin.performImport(
            source: RoundTripImportFile(files),
            sink: SQLiteImportSink(database),
            progress: PluginImportProgress(progress: Progress(totalUnitCount: 1))
        )
        #expect(result.errors.isEmpty)
    }

    // MARK: Row formats

    static func csv(_ options: CSVExportOptions, importing: CSVImportOptions = CSVImportOptions()) async throws -> RoundTripDatabase {
        let source = try RoundTripFixture.database()
        let written = try await CSVExportHarness.shared.bytes(
            options: options,
            tables: [RoundTripFixture.exportTable()],
            dataSource: SQLiteExportSource(source)
        )
        let file = temporaryURL(fileExtension: "csv")
        try write(written.data, to: file)
        defer { remove([file]) }
        return try await importRows(CSVImportPlugin(), settings: importing, file: file)
    }

    static func json(_ options: JSONExportOptions) async throws -> RoundTripDatabase {
        let file = try await exportFile(JSONExportPlugin(), settings: options, fileExtension: options.layout.fileExtension)
        defer { remove([file]) }
        return try await importRows(JSONImportPlugin(), settings: JSONImportOptions(), file: file)
    }

    static func xlsx(_ options: XLSXExportOptions) async throws -> RoundTripDatabase {
        let file = try await exportFile(XLSXExportPlugin(), settings: options, fileExtension: "xlsx")
        defer { remove([file]) }
        return try await importRows(XLSXImportPlugin(), settings: XLSXImportOptions(), file: file)
    }

    private static func exportFile<Plugin: ExportFormatPlugin & SettablePlugin>(
        _ plugin: Plugin,
        settings: Plugin.Settings,
        fileExtension: String
    ) async throws -> URL {
        let database = try RoundTripFixture.database()
        return try await exportFile(plugin, settings: settings, from: SQLiteExportSource(database), fileExtension: fileExtension)
    }

    static func exportFile<Plugin: ExportFormatPlugin & SettablePlugin>(
        _ plugin: Plugin,
        settings: Plugin.Settings,
        from source: any PluginExportDataSource,
        fileExtension: String
    ) async throws -> URL {
        let stored = plugin.settings
        plugin.settings = settings
        defer { plugin.settings = stored }
        let file = temporaryURL(fileExtension: fileExtension)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await plugin.export(
            tables: [RoundTripFixture.exportTable()],
            dataSource: source,
            destination: file,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return file
    }

    private static func importRows<Plugin: ImportFormatPlugin & SettablePlugin>(
        _ plugin: Plugin,
        settings: Plugin.Settings,
        file: URL
    ) async throws -> RoundTripDatabase {
        let target = try RoundTripFixture.emptyDatabase()
        let stored = plugin.settings
        plugin.settings = settings
        defer { plugin.settings = stored }
        let result = try await plugin.performImport(
            source: RoundTripImportFile(file),
            sink: SQLiteImportSink(target, targetTable: RoundTripFixture.table),
            progress: PluginImportProgress(progress: Progress(totalUnitCount: 1))
        )
        #expect(result.errors.isEmpty)
        #expect(result.skippedStatements == 0)
        return target
    }
}

private final class TypedRowSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    private let header: PluginStreamHeader
    private let rows: [PluginRow]

    init(columns: [String], columnTypeNames: [String], rows: [PluginRow]) {
        header = PluginStreamHeader(columns: columns, columnTypeNames: columnTypeNames)
        self.rows = rows
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let header = header
        let rows = rows
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(header))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { identifier }

    func escapeStringLiteral(_ value: String) -> String { value }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}
