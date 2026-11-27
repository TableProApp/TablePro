//
//  SqlFileImportSourceGzipTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

/// A `.sql.gz` import used to inflate the whole dump to a temporary `.sql` before the first
/// statement, writing the uncompressed size to disk and reading it back. The source now reads the
/// statements through the parser's inflater, so the temporary directory gains nothing.
/// Serialized because it watches the shared temporary directory for an expanded copy.
@Suite("SQL file import source reads gzip in place", .serialized)
struct SqlFileImportSourceGzipTests {
    private func writeGzip(_ sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sql-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = directory.appendingPathComponent("dump.sql")
        try sql.write(to: plain, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = [plain.path]
        process.environment = [:]
        try process.run()
        process.waitUntilExit()

        return directory.appendingPathComponent("dump.sql.gz")
    }

    private func temporarySQLFiles() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return Set(contents.filter { $0.pathExtension == "sql" }.map(\.lastPathComponent))
    }

    @Test("A gzipped dump yields its statements with no expanded copy on disk")
    func gzipIsReadInPlace() async throws {
        let sql = (1...300).map { "INSERT INTO t VALUES (\($0));\n" }.joined()
        let archive = try writeGzip(sql)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let before = temporarySQLFiles()

        let source = SqlFileImportSource(url: archive, encoding: .utf8, grammar: { TestGrammar.standard })
        var statements: [String] = []
        for try await (statement, _) in try await source.statements() {
            statements.append(statement)
        }

        #expect(statements.count == 300)
        #expect(statements.first == "INSERT INTO t VALUES (1)")
        #expect(temporarySQLFiles().subtracting(before).isEmpty)
    }

    @Test("Progress reads the compressed bytes against the size of the file on disk")
    func progressFollowsCompressedBytes() async throws {
        let sql = (1...3_000).map { "INSERT INTO t VALUES (\($0), 'row');\n" }.joined()
        let archive = try writeGzip(sql)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let onDisk = try #require(
            try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64
        )
        let last = OSAllocatedUnfairLock<(read: Int64, size: Int64)?>(initialState: nil)

        let source = SqlFileImportSource(url: archive, encoding: .utf8, grammar: { TestGrammar.standard })
        source.reportsReading { read, size in last.withLock { $0 = (read, size) } }
        for try await _ in try await source.statements() {}

        #expect(source.fileSizeBytes() == onDisk)
        let report = try #require(last.withLock { $0 })
        #expect(report.size == onDisk)
        #expect(report.read == onDisk)
    }
}
