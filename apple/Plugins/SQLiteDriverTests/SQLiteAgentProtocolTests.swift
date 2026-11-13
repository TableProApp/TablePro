//
//  SQLiteAgentProtocolTests.swift
//  TableProTests
//

import Foundation
import Testing

struct SQLiteAgentProtocolTests {
    private func roundTrip(_ reply: SQLiteAgentReply) throws -> SQLiteAgentReply {
        var reader = SQLiteAgentFrameReader()
        reader.append(SQLiteAgentFrameEncoder.encode(reply))
        let decoded = try reader.nextReply()
        return try #require(decoded)
    }

    private func roundTrip(_ request: SQLiteAgentRequest) throws -> SQLiteAgentRequest {
        var reader = SQLiteAgentFrameReader()
        reader.append(SQLiteAgentFrameEncoder.encode(request))
        let decoded = try reader.nextRequest()
        return try #require(decoded)
    }

    @Test func readyRoundTrips() throws {
        let reply = try roundTrip(.ready(protocolVersion: 1, sqliteVersion: "3.45.1", pythonVersion: "3.12.3"))
        #expect(reply == .ready(protocolVersion: 1, sqliteVersion: "3.45.1", pythonVersion: "3.12.3"))
    }

    @Test func headerCarriesNilAndPresentDeclaredTypes() throws {
        let columns = [
            SQLiteAgentColumn(name: "a", declaredType: "INTEGER"),
            SQLiteAgentColumn(name: "expr", declaredType: nil),
            SQLiteAgentColumn(name: "b", declaredType: "VARCHAR(9)"),
        ]
        let reply = try roundTrip(.header(columns))
        #expect(reply == .header(columns))
    }

    @Test func rowsPreserveNullEmptyTextAndBlobBytes() throws {
        let values: [SQLiteAgentValue] = [
            .null,
            .text(Data()),
            .text(Data("9223372036854775807".utf8)),
            .blob(Data([0x00, 0xFF])),
        ]
        let reply = try roundTrip(.rows(columnCount: 2, values: values))
        #expect(reply == .rows(columnCount: 2, values: values))
    }

    @Test func doneCarriesNegativeAndLargeChanges() throws {
        #expect(try roundTrip(.done(changes: 0, truncated: false)) == .done(changes: 0, truncated: false))
        #expect(try roundTrip(.done(changes: 5, truncated: true)) == .done(changes: 5, truncated: true))
    }

    @Test func errorRoundTripsWithNegativeCode() throws {
        let reply = try roundTrip(.error(code: -1, message: "not authorized"))
        #expect(reply == .error(code: -1, message: "not authorized"))
    }

    @Test func executeRequestRoundTripsWithMixedParameters() throws {
        let request = SQLiteAgentRequest.execute(
            sql: "SELECT * FROM t WHERE a = ? AND b = ?",
            parameters: [.text(Data("x".utf8)), .blob(Data([0x01, 0x02]))],
            rowCap: 500
        )
        #expect(try roundTrip(request) == request)
    }

    @Test func helloRoundTrips() throws {
        let request = SQLiteAgentRequest.hello(protocolVersion: 1, path: "~/app.db", busyTimeoutMilliseconds: 2000)
        #expect(try roundTrip(request) == request)
    }

    @Test func launcherNoticeIsReadBeforeAnyFrame() throws {
        var reader = SQLiteAgentFrameReader()
        reader.append(Data((SQLiteAgentProtocol.noPythonNotice + "\n").utf8))
        let notice = try reader.nextReply()
        #expect(notice == .launcherNotice(SQLiteAgentProtocol.noPythonNotice))
    }

    @Test func framesReassembleAcrossChunkBoundaries() throws {
        let encoded = SQLiteAgentFrameEncoder.encode(SQLiteAgentReply.done(changes: 3, truncated: false))
        var reader = SQLiteAgentFrameReader()
        reader.append(encoded.prefix(2))
        #expect(try reader.nextReply() == nil)
        reader.append(encoded.suffix(from: encoded.index(encoded.startIndex, offsetBy: 2)))
        #expect(try reader.nextReply() == .done(changes: 3, truncated: false))
    }

    // The reader drops what it already decoded between reads, so a long stream must not lose or repeat a byte.
    @Test func longStreamSplitAcrossReadsDecodesEveryFrame() throws {
        let replies = (0..<300).map { index in
            SQLiteAgentReply.rows(columnCount: 2, values: [.text(Data("\(index)".utf8)), .blob(Data(repeating: UInt8(index % 256), count: index * 37))])
        }
        var stream = Data()
        for reply in replies { stream.append(SQLiteAgentFrameEncoder.encode(reply)) }

        var reader = SQLiteAgentFrameReader()
        var decoded: [SQLiteAgentReply] = []
        var offset = 0
        var chunk = 1
        while offset < stream.count {
            let end = min(offset + chunk, stream.count)
            reader.append(stream.subdata(in: offset..<end))
            while let reply = try reader.nextReply() { decoded.append(reply) }
            offset = end
            chunk = chunk * 7 % 32_771 + 1
        }
        #expect(decoded == replies)
    }

    @Test func oversizeFrameLengthIsRejected() {
        var reader = SQLiteAgentFrameReader()
        var header = Data()
        withUnsafeBytes(of: UInt32(SQLiteAgentProtocol.maxFrameLength + 1).bigEndian) { header.append(contentsOf: $0) }
        reader.append(header)
        #expect(throws: SQLiteAgentProtocolError.self) { _ = try reader.nextReply() }
    }
}
