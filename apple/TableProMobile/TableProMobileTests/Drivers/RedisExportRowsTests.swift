import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

struct RedisExportRowsTests {
    // Answers by the command's first two words; anything unscripted is an error reply.
    private struct Server: Sendable {
        let replies: [String: RedisReplyValue]
        let bytes: [String: Data]

        var send: RedisExportRows.Send {
            let replies = replies
            return { arguments in replies[arguments.prefix(2).joined(separator: " ")] ?? .error("NOPERM") }
        }

        var readBytes: RedisExportRows.ReadBytes {
            let bytes = bytes
            return { arguments in bytes[arguments.prefix(2).joined(separator: " ")] }
        }
    }

    @Test("The export statement names the database it reads, and anything else runs as a command")
    func readsTheRequest() {
        #expect(RedisExportRows.request(for: "KEYBROWSE DB 3") == .keyBrowse(database: 3))
        #expect(RedisExportRows.request(for: "keybrowse") == .keyBrowse(database: nil))
        #expect(RedisExportRows.request(for: "GET a") == .command)
    }

    @Test("A string key reads whole: UTF-8 as text, anything else as its bytes, with its type, TTL and length")
    func stringKeys() async throws {
        let server = Server(
            replies: [
                "TYPE text": .status("string"), "TTL text": .integer(-1), "STRLEN text": .integer(5),
                "TYPE raw": .status("string"), "TTL raw": .integer(30), "STRLEN raw": .integer(2),
            ],
            bytes: ["GET text": Data("héllo".utf8), "GET raw": Data([0xFF, 0x00])]
        )

        let rows = try await RedisExportRows.rows(keys: ["text", "raw"], send: server.send, readBytes: server.readBytes)

        #expect(rows == [
            [.text("text"), .text("STRING"), .text("-1"), .text("5"), .text("héllo")],
            [.text("raw"), .text("STRING"), .text("30"), .text("2"), .bytes(Data([0xFF, 0x00]))],
        ])
    }

    @Test("A collection's value is the Mac's JSON preview of it")
    func collectionPreviews() async throws {
        let server = Server(
            replies: [
                "TYPE h": .status("hash"), "TTL h": .integer(-1), "HLEN h": .integer(2),
                "HSCAN h": .array([.string("0"), .array([.string("b"), .string("2"), .string("a"), .string("1")])]),
                "TYPE l": .status("list"), "TTL l": .integer(-1), "LLEN l": .integer(2),
                "LRANGE l": .array([.string("x"), .string("y")]),
            ],
            bytes: [:]
        )

        let rows = try await RedisExportRows.rows(keys: ["h", "l"], send: server.send, readBytes: server.readBytes)

        #expect(rows[0][4] == .text(#"{"a":"1","b":"2"}"#))
        #expect(rows[1][4] == .text(#"["x","y"]"#))
    }

    @Test("A key the server will not describe keeps its name and leaves the other cells empty")
    func refusedKey() async throws {
        let server = Server(replies: [:], bytes: [:])

        let rows = try await RedisExportRows.rows(keys: ["secret"], send: server.send, readBytes: server.readBytes)

        #expect(rows == [[.text("secret"), .null, .null, .null, .null]])
    }

    @Test("The columns are the Mac's KEYBROWSE columns, in its order")
    func columns() {
        #expect(RedisExportRows.columns == ["Key", "Type", "TTL", "Length", "Value"])
        #expect(RedisExportRows.columnTypeNames == ["String", "RedisType", "RedisInt", "Int64", "RedisRaw"])
    }
}
