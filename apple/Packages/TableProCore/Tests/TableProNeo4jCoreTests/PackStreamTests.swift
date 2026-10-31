import Foundation
@testable import TableProNeo4jCore
import Testing

struct PackStreamTests {
    @Test("Integers use the smallest marker the Bolt spec allows", arguments: [
        (Int64(1), [0x01]),
        (Int64(-16), [0xF0]),
        (Int64(-17), [0xC8, 0xEF]),
        (Int64(128), [0xC9, 0x00, 0x80]),
        (Int64(-129), [0xC9, 0xFF, 0x7F]),
        (Int64(32_768), [0xCA, 0x00, 0x00, 0x80, 0x00]),
        (Int64(2_147_483_648), [0xCB, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00])
    ] as [(Int64, [UInt8])])
    func integers(value: Int64, bytes: [UInt8]) throws {
        #expect([UInt8](PackStreamEncoder.encode(.int(value))) == bytes)
        #expect(try PackStreamDecoder.decode(Data(bytes)) == .int(value))
    }

    @Test("Strings, lists and maps round-trip through tiny and sized headers")
    func containers() throws {
        let long = String(repeating: "a", count: 300)
        let value = PackStreamValue.map([
            "short": .string("hi"),
            "long": .string(long),
            "list": .list((0 ..< 20).map { .int($0) }),
            "nested": .map(["flag": .bool(true), "none": .null, "pi": .float(3.14)]),
            "bytes": .bytes(Data([1, 2, 3]))
        ])
        #expect(try PackStreamDecoder.decode(PackStreamEncoder.encode(value)) == value)
    }

    @Test("The spec's example string encodes byte for byte")
    func specString() {
        #expect([UInt8](PackStreamEncoder.encode(.string("a"))) == [0x81, 0x61])
        #expect([UInt8](PackStreamEncoder.encode(.float(1.1))) == [0xC1, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A])
    }

    @Test("A value cut short is refused instead of read as garbage")
    func truncated() {
        #expect(throws: PackStreamError.truncated) { try PackStreamDecoder.decode(Data([0xD0, 0x05, 0x61])) }
        #expect(throws: PackStreamError.unknownMarker(0xC4)) { try PackStreamDecoder.decode(Data([0xC4])) }
    }
}

struct BoltMessageTests {
    @Test("The handshake offers 5.4 down to 5.0, then 4.4 down to 4.2")
    func handshake() {
        #expect([UInt8](BoltHandshake.request.prefix(8)) == [0x60, 0x60, 0xB0, 0x17, 0x00, 0x04, 0x04, 0x05])
        #expect(BoltHandshake.version(fromResponse: [0, 0, 4, 5]) == BoltVersion(major: 5, minor: 4))
        #expect(BoltHandshake.version(fromResponse: [0, 0, 0, 0]) == nil)
    }

    @Test("RESET is a field-less structure in one chunk and an end marker")
    func reset() {
        #expect([UInt8](BoltRequest.reset.framed) == [0x00, 0x02, 0xB0, 0x0F, 0x00, 0x00])
    }

    @Test("A message over 64 KiB is split into several chunks and joined back")
    func chunking() throws {
        let query = String(repeating: "x", count: 70_000)
        let framed = BoltRequest.run(query: query, parameters: [:], extra: [:]).framed
        #expect(framed[0] == 0xFF && framed[1] == 0xFF)

        var dechunker = BoltDechunker()
        dechunker.append([0x00, 0x00])
        dechunker.append(framed.prefix(100))
        #expect(try dechunker.nextMessage() == nil)
        dechunker.append(framed.dropFirst(100))
        let message = try #require(try dechunker.nextMessage())
        guard case .structure(0x10, let fields) = try PackStreamDecoder.decode(message) else {
            Issue.record("not a RUN structure")
            return
        }
        #expect(fields.first == .string(query))
        #expect(try dechunker.nextMessage() == nil)
    }

    @Test("Replies decode to success, record, ignored and failure")
    func responses() throws {
        func message(_ tag: UInt8, _ fields: [PackStreamValue]) -> Data {
            PackStreamEncoder.encode(.structure(tag: tag, fields: fields))
        }
        #expect(try BoltResponse.decode(message(0x70, [.map(["fields": .list([.string("n")])])]))
            == .success(["fields": .list([.string("n")])]))
        #expect(try BoltResponse.decode(message(0x71, [.list([.int(1)])])) == .record([.int(1)]))
        #expect(try BoltResponse.decode(message(0x7E, [])) == .ignored)
        #expect(try BoltResponse.decode(message(0x7F, [.map([
            "code": .string("Neo.ClientError.Statement.SyntaxError"), "message": .string("bad")
        ])])) == .failure(code: "Neo.ClientError.Statement.SyntaxError", message: "bad"))
    }
}
