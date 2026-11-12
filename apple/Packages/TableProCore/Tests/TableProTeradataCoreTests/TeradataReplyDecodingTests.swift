@testable import TableProTeradataCore
import TableProWireIO
import Testing

struct TeradataReplyDecodingTests {
    private static let key = [UInt8](repeating: 0x42, count: 32)

    private static func reply(charLength: [UInt8], record: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [
            0x00, 0x7D, 0x00, 0x23,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x01, 0xC4,
        ]
        bytes += charLength
        bytes += [0x00, 0x00, 0x00, 0x01, 0x63, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x0A, 0x00, UInt8(4 + record.count)]
        bytes += record
        bytes += [0x00, 0x0C, 0x00, 0x04]
        return bytes
    }

    private static func execute(_ reply: [UInt8]) throws -> TeradataResultSet {
        let transport = StoppableTransport(replies: [LanMessage(kind: .start, body: reply).encoded()])
        let config = TeradataConnectionConfig(host: "td.example", username: "dbc", password: "dbc")
        return try TeradataConnection(config: config, transport: transport).execute("SELECT c FROM t")
    }

    @Test("A result description whose CHAR column has length -1 fails the reply instead of crashing")
    func negativeColumnLengthFailsTheReply() throws {
        let reply = Self.reply(charLength: [UInt8](repeating: 0xFF, count: 8), record: [0x00, 0x78])
        #expect(reply.count == 45)
        let parcels = try Parcel.decodeAll(reply)
        let flavors = parcels.map(\.flavor)
        #expect(flavors == [ParcelFlavor.prepInfoX.rawValue, ParcelFlavor.record.rawValue, ParcelFlavor.endRequest.rawValue])
        #expect(throws: WireIOError.lengthOutOfRange("-1", limit: 1)) { try Self.execute(reply) }
    }

    @Test("A CHAR column of the declared length still decodes")
    func charColumnDecodes() throws {
        let reply = Self.reply(charLength: [0, 0, 0, 0, 0, 0, 0, 3], record: [0x00, 0x61, 0x62, 0x63])
        let result = try Self.execute(reply)
        #expect(result.rows == [[TeradataValue.text("abc")]])
    }

    @Test("A DER length of eight 0xFF bytes in an encrypted reply fails instead of crashing")
    func oversizedDerLengthFailsTheReply() {
        let der: [UInt8] = [0xE0, 0x10, 0xC0, 0x88] + [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0x00, count: 6)
        #expect(throws: WireIOError.self) { try Td2Wrap.unwrap(der: der, key: Self.key) }
    }

    @Test("An encrypted message with long-form DER lengths unwraps to its plaintext")
    func encryptedMessageRoundTrips() throws {
        let plaintext = (0..<300).map { UInt8(truncatingIfNeeded: $0) }
        let der = try Td2Wrap.wrap(plaintext: plaintext, key: Self.key, sequenceNumber: 7)
        #expect(try Td2Wrap.unwrap(der: der, key: Self.key) == plaintext)
    }
}
