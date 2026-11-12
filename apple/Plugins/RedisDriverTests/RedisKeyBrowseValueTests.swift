//
//  RedisKeyBrowseValueTests.swift
//  RedisDriverTests
//

import Foundation
import TableProPluginKit
import TableProRedisCore
import Testing

struct RedisKeyBrowseValueTests {
    private func driver() -> RedisPluginDriver {
        RedisPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: 6_379, username: "", password: "", database: "0"
        ))
    }

    private static func scanReply(_ keys: [String]) -> RedisReply {
        .array([.string("0"), .array(keys.map(RedisReply.string))])
    }

    @Test("The grid reads a long string's start and marks it shortened, with its whole length")
    func gridShowsTheStartOfALongString() async throws {
        let start = String(repeating: "a", count: RedisStringPreview.byteLimit)
        let channel = StubRedisChannel([
            Self.scanReply(["page:1"]),
            .status("string"), .integer(-1),
            .integer(900_000), .string(start),
        ])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("KEYBROWSE LIMIT 100 OFFSET 0"), connection: channel, startTime: Date()
        )
        #expect(channel.sentCommands.last == ["GETRANGE", "page:1", "0", String(RedisStringPreview.byteLimit - 1)])
        let row = try #require(result.rows.first)
        #expect(row[3] == .text("900000"))
        #expect(row[4] == .text(start + RedisStringPreview.marker))
    }

    @Test("A short string in the grid shows whole and unmarked")
    func gridShowsAShortStringWhole() async throws {
        let channel = StubRedisChannel([
            Self.scanReply(["k"]),
            .status("string"), .integer(-1),
            .integer(5), .string("hello"),
        ])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("KEYBROWSE LIMIT 100 OFFSET 0"), connection: channel, startTime: Date()
        )
        #expect(result.rows.first?[4] == .text("hello"))
    }

    @Test("A long binary string in the grid stays bytes")
    func gridKeepsBinaryAsBytes() async throws {
        let blob = Data([0x1F, 0x8B, 0x08, 0x00, 0xFF, 0xFE])
        let channel = StubRedisChannel([
            Self.scanReply(["bin"]),
            .status("string"), .integer(-1),
            .integer(900_000), .data(blob),
        ])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("KEYBROWSE LIMIT 100 OFFSET 0"), connection: channel, startTime: Date()
        )
        #expect(result.rows.first?[4] == .bytes(blob))
    }

    @Test("The export summary reads every string whole")
    func exportSummaryReadsWholeValues() async throws {
        let whole = String(repeating: "b", count: RedisStringPreview.byteLimit + 10)
        let channel = StubRedisChannel([
            .status("string"), .integer(-1),
            .integer(Int64(whole.utf8.count)), .string(whole),
        ])
        let rows = try await driver().buildKeySummaryRows(keys: ["doc"], connection: channel, stringByteLimit: nil)
        #expect(channel.sentCommands.last == ["GET", "doc"])
        #expect(rows.first?[4] == .text(whole))
    }

    @Test("KEYS summarizes its keys in batches, never one pipeline for every key")
    func keysSummarizedInBatches() async throws {
        let keys = (0 ..< 250).map { "k\($0)" }
        let channel = StubRedisChannel([.array(keys.map(RedisReply.string))])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("KEYS *"), connection: channel, startTime: Date()
        )
        #expect(result.rows.count == 250)
        #expect(result.rows.map { $0[0] } == keys.map(PluginCellValue.text))
        #expect(channel.pipelineSizes == [RedisPluginDriver.keySummaryBatchSize * 2, 100])
    }

    @Test("A SCAN page summarizes its keys in batches")
    func scanPageSummarizedInBatches() async throws {
        let keys = (0 ..< 250).map { "k\($0)" }
        let channel = StubRedisChannel([Self.scanReply(keys)])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("SCAN 0 COUNT 300"), connection: channel, startTime: Date()
        )
        #expect(result.rows.count == 250)
        #expect(channel.pipelineSizes == [RedisPluginDriver.keySummaryBatchSize * 2, 100])
    }

    @Test("A key that starts with a byte order mark is deleted by its own name")
    func byteOrderMarkKeyDeletesItself() throws {
        let markedKey = "\u{FEFF}user:1"
        let generator = RedisStatementGenerator(namespaceName: "", columns: ["Key", "Type", "TTL", "Length", "Value"])
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text(markedKey), "string", "-1", "1", "v"]
        )
        let writes = try generator.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        guard case .del(let deleted)? = try? RedisCommandParser.parse(writes[0].statement) else {
            Issue.record("expected a DEL")
            return
        }
        #expect(deleted.map { Data($0.utf8) } == [Data([0xEF, 0xBB, 0xBF] + Array("user:1".utf8))])
    }
}
