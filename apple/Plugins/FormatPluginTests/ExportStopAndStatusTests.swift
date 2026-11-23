//
//  ExportStopAndStatusTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

// Pulled, so the stop lands after the plugin has read the last row and before the stream reports its end.
private final class StopAfterLastRowSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "SQLite"
    private let progress: PluginExportProgress

    init(progress: PluginExportProgress) {
        self.progress = progress
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let progress = progress
        let pulls = PullCount()
        return AsyncThrowingStream(unfolding: {
            switch await pulls.next() {
            case 0:
                return .header(PluginStreamHeader(columns: ["id", "name"], columnTypeNames: ["INTEGER", "TEXT"]))
            case 1:
                return .rows([[.text("1"), .text("Ada")], [.text("2"), .text("Grace")]])
            default:
                progress.cancel()
                return nil
            }
        })
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }

    func escapeStringLiteral(_ value: String) -> String { value }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

private actor PullCount {
    private var value = 0

    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

private final class DefinitionSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["INTEGER"])))
            continuation.yield(.rows([[.text("1")]]))
            continuation.finish()
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        "CREATE TABLE \(table) (id INTEGER)"
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        switch object.kind {
        case .view: return "CREATE VIEW \(object.name) AS SELECT 1"
        case .routine: return "CREATE FUNCTION \(object.name)() RETURNS integer AS $$ SELECT 1 $$ LANGUAGE sql"
        default: return try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }

    func escapeStringLiteral(_ value: String) -> String { value }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ status: String) {
        lock.lock()
        entries.append(status)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

struct ExportStopAndStatusTests {
    private let table = PluginExportTable(name: "t", databaseName: "", tableType: "table", schema: nil, kind: .table)

    private func temporaryURL(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
    }

    private func expectStopAfterLastRowWritesNothing(
        _ plugin: any ExportFormatPlugin,
        fileExtension: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 2))
        let destination = temporaryURL(fileExtension)
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: PluginExportCancellationError.self, sourceLocation: sourceLocation) {
            _ = try await plugin.export(
                tables: [table],
                dataSource: StopAfterLastRowSource(progress: progress),
                destination: destination,
                progress: progress
            )
        }
        #expect(
            !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)),
            sourceLocation: sourceLocation)
    }

    @Test("XLSX stopped after the last row writes no workbook")
    func xlsxStoppedAfterLastRow() async {
        await expectStopAfterLastRowWritesNothing(XLSXExportPlugin(), fileExtension: "xlsx")
    }

    @Test("Markdown stopped after the last row writes no file")
    func markdownStoppedAfterLastRow() async {
        await expectStopAfterLastRowWritesNothing(MarkdownExportPlugin(), fileExtension: "md")
    }

    @Test("XLSX stopped while it copies the sheets into the archive writes no workbook, after reporting its bytes")
    func xlsxStoppedDuringArchive() async throws {
        let writer = XLSXWriter()
        try writer.beginSheet(name: "t", columns: ["v"], includeHeader: false, convertNullToEmpty: true)
        // Seeded random base64 barely deflates: 320 cells of 32 KiB, under Excel's cell limit, make about 7.75 MiB of
        // sheet in the archive.
        var state: UInt64 = 0x5EED_0C0F
        let rows: [[PluginCellValue]] = (0..<320).map { _ in
            let bytes = (0..<(24 * 1_024)).map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 33)
            }
            return [.text(Data(bytes).base64EncodedString())]
        }
        try writer.addRows(rows, convertNullToEmpty: true)
        try writer.finishSheet()

        let nsProgress = Progress(totalUnitCount: 1)
        let progress = PluginExportProgress(progress: nsProgress)
        // The first status arrives once 4 MiB of the deflated sheet are copied, so the stop lands mid-copy.
        let observation = nsProgress.observe(\.localizedAdditionalDescription) { observed, _ in
            if observed.localizedAdditionalDescription?.isEmpty == false { observed.cancel() }
        }
        defer { observation.invalidate() }
        let destination = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: PluginExportCancellationError.self) {
            try await writer.write(to: destination, progress: progress)
        }
        #expect(nsProgress.localizedAdditionalDescription?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test("A SQL dump moves its status once for each object it fetches after the rows")
    func sqlDefinitionsMoveTheStatus() async throws {
        let nsProgress = Progress(totalUnitCount: 1)
        let progress = PluginExportProgress(progress: nsProgress)
        let log = StatusLog()
        let observation = nsProgress.observe(\.localizedAdditionalDescription) { observed, _ in
            log.append(observed.localizedAdditionalDescription ?? "")
        }
        defer { observation.invalidate() }
        let kinds: [(name: String, kind: PluginExportObjectKind)] = [
            ("orders", .table), ("v_orders", .view), ("p_orders", .routine)
        ]
        let objects = kinds.map { entry in
            PluginExportTable(
                name: entry.name, databaseName: "", tableType: entry.kind.rawValue, optionValues: [true, true, true],
                schema: nil, kind: entry.kind)
        }

        _ = try await SQLExportHarness.shared.dump(tables: objects, dataSource: DefinitionSource(), progress: progress)

        // The table's index read, then the view's and the routine's definitions.
        let statuses = log.all.filter { !$0.isEmpty }
        #expect(Set(statuses).count == 3)
        #expect(statuses.last?.hasSuffix("3 of 3") == true)
    }
}
