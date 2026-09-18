//
//  RedisBinaryValueTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private let browseColumns = ["Key", "Type", "TTL", "Length", "Value"]
private let gzipPayload = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0xFE])

private func updateStatements(
    key: String = "mykey",
    type: String = "STRING",
    newValue: PluginCellValue
) -> [(statement: String, parameters: [PluginCellValue])] {
    let generator = RedisStatementGenerator(namespaceName: "", columns: browseColumns)
    let change = PluginRowChange(
        rowIndex: 0,
        type: .update,
        cellChanges: [(columnIndex: 4, columnName: "Value", oldValue: .text("old"), newValue: newValue)],
        originalRow: [.text(key), .text(type), "-1", "3", .text("old")]
    )
    return generator.generateStatements(
        from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
    )
}

private func parsedValue(of statement: String) -> Data? {
    guard case .set(_, let value, _)? = try? RedisCommandParser.parse(statement) else { return nil }
    return value
}

@Suite("Redis write path - values survive the command round-trip")
struct RedisWriteRoundTripTests {
    @Test("a plain value produces a readable command")
    func plainValueStaysReadable() {
        let statements = updateStatements(newValue: .text("hello"))
        #expect(statements.count == 1)
        #expect(statements.first?.statement == "SET mykey hello")
    }

    @Test("a value with spaces is quoted and parses back whole")
    func spacedValueRoundTrips() {
        let statements = updateStatements(newValue: .text("hello world"))
        #expect(statements.first?.statement == "SET mykey \"hello world\"")
        #expect(parsedValue(of: statements[0].statement) == Data("hello world".utf8))
    }

    @Test("quotes, backslashes, and newlines round-trip")
    func specialCharactersRoundTrip() {
        let value = "a\"b\\c\nd"
        let statements = updateStatements(newValue: .text(value))
        #expect(parsedValue(of: statements[0].statement) == Data(value.utf8))
    }

    @Test("non-ASCII text round-trips")
    func unicodeRoundTrips() {
        let value = "café ☕"
        let statements = updateStatements(newValue: .text(value))
        #expect(parsedValue(of: statements[0].statement) == Data(value.utf8))
    }

    @Test("a long value round-trips whole")
    func longValueRoundTrips() {
        let value = String(repeating: "x", count: 20_000)
        let statements = updateStatements(newValue: .text(value))
        #expect(parsedValue(of: statements[0].statement) == Data(value.utf8))
    }

    @Test("a binary value round-trips byte for byte")
    func binaryValueRoundTrips() {
        let statements = updateStatements(newValue: .bytes(gzipPayload))
        #expect(statements.count == 1)
        #expect(parsedValue(of: statements[0].statement) == gzipPayload)
    }

    @Test("binary blobs of many shapes round-trip")
    func binaryBlobsRoundTrip() {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextByte() -> UInt8 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        }
        for length in 1 ... 120 {
            let blob = Data((0 ..< length).map { _ in nextByte() })
            let statements = updateStatements(newValue: .bytes(blob))
            #expect(parsedValue(of: statements[0].statement) == blob)
        }
    }

    @Test("a key containing a space round-trips")
    func keyWithSpaceRoundTrips() {
        let statements = updateStatements(key: "my key", newValue: .text("v"))
        guard case .set(let key, _, _)? = try? RedisCommandParser.parse(statements[0].statement) else {
            Issue.record("Expected a SET operation")
            return
        }
        #expect(key == "my key")
    }

    @Test("a value cannot inject a second command")
    func valueCannotInjectCommand() {
        let hostile = "x\" \nDEL victim \"y"
        let statements = updateStatements(newValue: .text(hostile))
        #expect(statements.count == 1)
        #expect(RedisArgumentCodec.split(statements[0].statement)?.count == 3)
        #expect(parsedValue(of: statements[0].statement) == Data(hostile.utf8))
    }

    @Test("a collection value is still refused so the structure survives")
    func collectionValueRefused() {
        #expect(updateStatements(type: "LIST", newValue: .text("[\"a\"]")).isEmpty)
    }

    @Test("a binary insert round-trips")
    func binaryInsertRoundTrips() {
        let generator = RedisStatementGenerator(namespaceName: "", columns: browseColumns)
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let inserted: [Int: [PluginCellValue]] = [
            0: [.text("bin"), .text("STRING"), .null, .null, .bytes(gzipPayload)]
        ]
        let statements = generator.generateStatements(
            from: [change], insertedRowData: inserted, deletedRowIndices: [], insertedRowIndices: [0]
        )
        #expect(statements.count == 1)
        #expect(parsedValue(of: statements[0].statement) == gzipPayload)
    }
}

@Suite("RedisCommandParser - binary arguments")
struct RedisCommandParserBinaryTests {
    @Test("SET carries a binary value through")
    func setCarriesBinary() {
        let command = "SET k \(RedisArgumentCodec.quote(gzipPayload))"
        guard case .set(let key, let value, _)? = try? RedisCommandParser.parse(command) else {
            Issue.record("Expected a SET operation")
            return
        }
        #expect(key == "k")
        #expect(value == gzipPayload)
    }

    @Test("LPUSH carries binary members through")
    func lpushCarriesBinary() {
        let command = "LPUSH l \(RedisArgumentCodec.quote(gzipPayload))"
        guard case .lpush(_, let values)? = try? RedisCommandParser.parse(command) else {
            Issue.record("Expected an LPUSH operation")
            return
        }
        #expect(values == [gzipPayload])
    }

    @Test("HSET carries a binary field value through")
    func hsetCarriesBinary() {
        let command = "HSET h field \(RedisArgumentCodec.quote(gzipPayload))"
        guard case .hset(_, let fieldValues)? = try? RedisCommandParser.parse(command) else {
            Issue.record("Expected an HSET operation")
            return
        }
        #expect(fieldValues.count == 1)
        #expect(fieldValues.first?.0 == "field")
        #expect(fieldValues.first?.1 == gzipPayload)
    }

    @Test("an unbalanced quote is rejected instead of silently mangled")
    func unbalancedQuoteRejected() {
        #expect((try? RedisCommandParser.parse("SET k \"oops")) == nil)
    }
}
