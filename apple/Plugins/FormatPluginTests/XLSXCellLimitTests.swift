//
//  XLSXCellLimitTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct XLSXCellLimitTests {
    private static let limit = XLSXWriter.maximumCellLength

    @Test("A value of up to 32,767 UTF-16 units is written whole, however many bytes it takes")
    func valuesAtTheLimitStayWhole() {
        for text in [String(repeating: "a", count: Self.limit), String(repeating: "é", count: Self.limit), ""] {
            let fitted = XLSXWriter.fittingExcelCell(text)
            #expect(!fitted.wasCut)
            #expect(fitted.text == text)
        }
    }

    @Test("A longer value keeps its first 32,767 units")
    func longerValuesAreCut() {
        for length in [Self.limit + 1, 40_000, 1 << 20] {
            let fitted = XLSXWriter.fittingExcelCell(String(repeating: "b", count: length))
            #expect(fitted.wasCut)
            #expect(fitted.text.utf16.count == Self.limit)
        }
    }

    @Test("A surrogate pair across the limit is dropped whole, never split")
    func emojiOnTheBoundaryIsNotSplit() {
        let text = String(repeating: "a", count: Self.limit - 1) + "😀" + "tail"
        let fitted = XLSXWriter.fittingExcelCell(text)
        #expect(fitted.wasCut)
        #expect(fitted.text == String(repeating: "a", count: Self.limit - 1))
        let whole = String(repeating: "a", count: Self.limit - 2) + "😀" + "tail"
        #expect(XLSXWriter.fittingExcelCell(whole).text == String(repeating: "a", count: Self.limit - 2) + "😀")
    }

    private final class LongValueSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "PostgreSQL"
        let rows: [PluginRow]

        init(rows: [PluginRow]) {
            self.rows = rows
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            let rows = rows
            return AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["id", "body"], columnTypeNames: ["int4", "text"])))
                continuation.yield(.rows(rows))
                continuation.finish()
            }
        }

        func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
            streamRows(table: object.name, databaseName: object.databaseName)
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String { identifier }

        func escapeStringLiteral(_ value: String) -> String { value }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    @Test("An export counts the values it cut in one warning, and the import reads them back cut")
    func exportWarnsAndImportReadsTheCutValue() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        let long = String(repeating: "c", count: 40_000)
        let source = LongValueSource(rows: [
            [.text("1"), .text(long)],
            [.text("2"), .text("short")],
            [.text("3"), .text(long)],
            [.text("4"), .text(String(repeating: "d", count: Self.limit))],
        ])
        let table = PluginExportTable(name: "t", databaseName: "", tableType: "table", schema: nil, kind: .table)
        let result = try await XLSXExportPlugin().export(
            tables: [table],
            dataSource: source,
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        let cutWarnings = result.warnings.filter { $0.contains("32,767") }
        #expect(cutWarnings.count == 1)
        #expect(cutWarnings.first?.contains(": 2.") == true)

        let sheet = try XLSXImportSheet.read(at: destination, hasHeaderRow: true, isCancelled: { false })
        let values = try sheet.rows(0 ..< sheet.rowCount).map { $0.values.last ?? nil }
        #expect(values.map { $0?.utf16.count } == [Self.limit, 5, Self.limit, Self.limit])
    }

    @Test("An export with no long value warns about nothing")
    func noWarningWithoutLongValues() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        let table = PluginExportTable(name: "t", databaseName: "", tableType: "table", schema: nil, kind: .table)
        let result = try await XLSXExportPlugin().export(
            tables: [table],
            dataSource: LongValueSource(rows: [[.text("1"), .text("short")]]),
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        #expect(result.warnings.isEmpty)
    }
}
