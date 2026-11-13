//
//  SQLFileParserBytesReadTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

private final class ReadReports: Sendable {
    struct Report: Equatable, Sendable {
        let read: Int64
        let size: Int64
    }

    private let reports = OSAllocatedUnfairLock<[Report]>(initialState: [])

    func record(read: Int64, size: Int64) {
        reports.withLock { $0.append(Report(read: read, size: size)) }
    }

    var all: [Report] {
        reports.withLock { $0 }
    }
}

struct SQLFileParserBytesReadTests {
    private static func withFile<T>(_ sql: String, _ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLFileParserBytesReadTests-\(UUID().uuidString).sql")
        try Data(sql.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    private static func expectGrowsToTheEnd(
        _ reports: [ReadReports.Report],
        of sql: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let fileSize = Int64(Data(sql.utf8).count)
        let grows = zip(reports, reports.dropFirst()).allSatisfy { pair in pair.0.read < pair.1.read }
        let sizes = Set(reports.map { report in report.size })

        #expect(reports.count > 1, sourceLocation: sourceLocation)
        #expect(grows, "\(reports.map { report in report.read })", sourceLocation: sourceLocation)
        #expect(reports.last?.read == fileSize, sourceLocation: sourceLocation)
        #expect(sizes == [fileSize], sourceLocation: sourceLocation)
    }

    @Test("Each chunk read reports the bytes read so far and the file's size, up to the whole file")
    func reportsEachChunk() async throws {
        let sql = (1...200).map { "SELECT \($0);\n" }.joined()
        let reports = ReadReports()
        let parser = SQLFileParser(chunkSize: 64)

        let (elements, count): (Int, Int) = try await Self.withFile(sql) { url in
            var yielded = 0
            let stream = parser.parseElements(
                url: url,
                encoding: .utf8,
                grammar: { TestGrammar.postgres },
                onRead: { read, size in reports.record(read: read, size: size) }
            )
            for try await _ in stream {
                yielded += 1
            }
            let counted = try await parser.countStatements(url: url, encoding: .utf8, grammar: TestGrammar.postgres)
            return (yielded, counted)
        }

        #expect(elements == 200)
        #expect(count == 200)
        Self.expectGrowsToTheEnd(reports.all, of: sql)
    }

    @Test("The statement stream reports reading the same way")
    func statementStreamReports() async throws {
        let sql = (1...100).map { "SELECT \($0);\n" }.joined()
        let reports = ReadReports()

        try await Self.withFile(sql) { url in
            let stream = SQLFileParser(chunkSize: 50).parseFile(
                url: url,
                encoding: .utf8,
                grammar: { TestGrammar.postgres },
                onRead: { read, size in reports.record(read: read, size: size) }
            )
            for try await _ in stream {}
        }

        Self.expectGrowsToTheEnd(reports.all, of: sql)
    }

    @Test("Bytes read grow while a COPY's rows are read, before the next element is asked for")
    func bytesGrowWhileCopyRowsAreRead() async throws {
        let rows = (1...2_000).map { "\($0)\trow \($0)\n" }.joined()
        let sql = "CREATE TABLE t (a int, b text);\nCOPY t (a, b) FROM stdin;\n\(rows)\\.\nSELECT 1;\n"
        let reports = ReadReports()
        let parser = SQLFileParser(chunkSize: 256, copyPieceLength: 128)

        let copies: Int = try await Self.withFile(sql) { url in
            var copiesRead = 0
            let stream = parser.parseElements(
                url: url,
                encoding: .utf8,
                grammar: { TestGrammar.postgres },
                onRead: { read, size in reports.record(read: read, size: size) }
            )
            for try await element in stream {
                guard case let .copyFromStandardInput(_, _, copyRows) = element else { continue }
                copiesRead += 1
                let before = reports.all
                var data = Data()
                while let piece = try copyRows.nextPiece() {
                    data.append(piece)
                }
                let after = reports.all

                #expect(data == Data(rows.utf8))
                #expect(after.count > before.count + 1)
                #expect((after.last?.read ?? 0) > (before.last?.read ?? 0))
            }
            return copiesRead
        }

        #expect(copies == 1)
        Self.expectGrowsToTheEnd(reports.all, of: sql)
    }

    @Test("The scan for GO lines before a SQL Server script is cut reports nothing")
    func batchSeparatorScanReportsNothing() async throws {
        let sql = (1...100).map { "SELECT \($0);\n" }.joined() + "GO\n"
        let reports = ReadReports()

        try await Self.withFile(sql) { url in
            let stream = SQLFileParser(chunkSize: 64).parseElements(
                url: url,
                encoding: .utf8,
                grammar: { TestGrammar.sqlServer },
                onRead: { read, size in reports.record(read: read, size: size) }
            )
            for try await _ in stream {}
        }

        Self.expectGrowsToTheEnd(reports.all, of: sql)
    }
}
