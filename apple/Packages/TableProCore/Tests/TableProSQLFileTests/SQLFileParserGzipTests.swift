import Foundation
import os
import TableProGzip
@testable import TableProSQLFile
import TableProSQLGrammar
import Testing

struct SQLFileParserGzipTests {
    private static func write(_ data: Data, extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLFileParserGzipTests-\(UUID().uuidString).\(pathExtension)")
        try data.write(to: url)
        return url
    }

    private static func statements(of url: URL, parser: SQLFileParser = SQLFileParser()) async throws -> [String] {
        var statements: [String] = []
        for try await (statement, _) in parser.parseFile(url: url, encoding: .utf8, grammar: TestGrammar.postgres) {
            statements.append(statement)
        }
        return statements
    }

    @Test("A gzip file parses to the statements of the SQL inside it, with no copy on disk")
    func gzipFileParsesLikeItsSQL() async throws {
        let sql = (1...5_000).map { "INSERT INTO t VALUES (\($0), 'row \($0);');\n" }.joined()
        let plain = try Self.write(Data(sql.utf8), extension: "sql")
        let packed = try Self.write(try GzipDeflater.compress(Data(sql.utf8)), extension: "sql.gz")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: packed)
        }

        let expected = try await Self.statements(of: plain)
        #expect(expected.count == 5_000)
        #expect(try await Self.statements(of: packed, parser: SQLFileParser(chunkSize: 512)) == expected)
        #expect(try await SQLFileParser().countStatements(url: packed, encoding: .utf8, grammar: TestGrammar.postgres) == 5_000)
    }

    @Test("A gzip file reports the compressed bytes read against its size on disk")
    func gzipReportsCompressedBytes() async throws {
        let sql = (1...2_000).map { "SELECT \($0);\n" }.joined()
        let packedData = try GzipDeflater.compress(Data(sql.utf8))
        let packed = try Self.write(packedData, extension: "sql.gz")
        defer { try? FileManager.default.removeItem(at: packed) }
        let last = OSAllocatedUnfairLock<(read: Int64, size: Int64)?>(initialState: nil)

        let stream = SQLFileParser(chunkSize: 256).parseFile(
            url: packed, encoding: .utf8, grammar: { TestGrammar.postgres },
            onRead: { read, size in last.withLock { $0 = (read, size) } }
        )
        var count = 0
        for try await _ in stream { count += 1 }

        #expect(count == 2_000)
        let report = try #require(last.withLock { $0 })
        #expect(report.size == Int64(packedData.count))
        #expect(report.read == Int64(packedData.count))
    }

    @Test("A gzip file cut short fails the parse instead of ending quietly")
    func truncatedGzipFails() async throws {
        let sql = (1...2_000).map { "SELECT \($0);\n" }.joined()
        let packedData = try GzipDeflater.compress(Data(sql.utf8))
        let packed = try Self.write(packedData.prefix(packedData.count - 12), extension: "sql.gz")
        defer { try? FileManager.default.removeItem(at: packed) }

        await #expect(throws: (any Error).self) {
            _ = try await Self.statements(of: packed)
        }
    }

    @Test("The preview reads the first bytes of SQL inside a gzip file")
    func previewReadsInflatedText() throws {
        let sql = String(repeating: "SELECT 1;\n", count: 10_000)
        let packed = try Self.write(try GzipDeflater.compress(Data(sql.utf8)), extension: "sql.gz")
        defer { try? FileManager.default.removeItem(at: packed) }

        let head = try SQLFileByteReader.leadingBytes(of: packed, limit: 1_000)
        #expect(head.data == Data(sql.utf8).prefix(1_000))
        #expect(!head.isWholeFile)
        let whole = try SQLFileByteReader.leadingBytes(of: packed, limit: 1 << 20)
        #expect(whole.data == Data(sql.utf8))
        #expect(whole.isWholeFile)
    }
}

struct SQLFileByteReaderBoundTests {
    @Test("A read of a gzip file that packs far returns about the size asked for, not the block's whole expansion")
    func readIsBoundedByOutput() throws {
        let zeros = Data(count: 64 << 20)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLFileByteReaderBoundTests-\(UUID().uuidString).sql.gz")
        try GzipDeflater.compress(zeros).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try SQLFileByteReader(url: url)
        let first = try reader.read(upToCount: 64 * 1_024)
        #expect(!first.isEmpty)
        #expect(first.count < 8 << 20)

        var total = first.count
        while true {
            let next = try reader.read(upToCount: 64 * 1_024)
            if next.isEmpty { break }
            total += next.count
        }
        #expect(total == zeros.count)
    }
}
