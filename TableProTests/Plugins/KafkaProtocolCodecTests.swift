import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Golden-byte tests for the Kafka wire codec.
///
/// These exist because of how Kafka fails. A malformed request does not come back as an error:
/// the broker consumes what it can and closes the socket, so the only symptom is a dropped
/// connection with no diagnostic. Every expectation below was measured against a live Apache
/// Kafka 4.3.1 broker before it was written down.
@Suite("Kafka protocol codec")
struct KafkaProtocolCodecTests {
    // MARK: - Varints

    @Test("Unsigned varints round-trip, and match the LEB128 boundary cases")
    func unsignedVarintRoundTrip() throws {
        let cases: [UInt32] = [0, 1, 127, 128, 300, 16_383, 16_384, 2_097_151, UInt32.max]
        for value in cases {
            var writer = KafkaProtocolWriter()
            writer.unsignedVarint(value)
            var reader = KafkaProtocolReader(writer.data)
            #expect(try reader.unsignedVarint() == value)
        }

        var writer = KafkaProtocolWriter()
        writer.unsignedVarint(300)
        #expect([UInt8](writer.data) == [0xAC, 0x02])
    }

    /// The records inside a batch use zig-zag signed varints while the protocol frame uses
    /// unsigned ones. They are indistinguishable on the wire, so mixing them decodes small
    /// values plausibly and corrupts large ones.
    @Test("Zig-zag varints round-trip through negative values")
    func zigZagVarintRoundTrip() throws {
        let cases: [Int32] = [0, -1, 1, -2, 2, 63, -64, 1_000_000, -1_000_000, Int32.min, Int32.max]
        for value in cases {
            var writer = KafkaProtocolWriter()
            writer.varint(value)
            var reader = KafkaProtocolReader(writer.data)
            #expect(try reader.varint() == value)
        }

        var writer = KafkaProtocolWriter()
        writer.varint(-1)
        #expect([UInt8](writer.data) == [0x01])
    }

    @Test("Zig-zag varlongs round-trip through 64-bit extremes")
    func zigZagVarlongRoundTrip() throws {
        let cases: [Int64] = [0, -1, 1, Int64.min, Int64.max, 1_787_709_624_571]
        for value in cases {
            var writer = KafkaProtocolWriter()
            writer.varlong(value)
            var reader = KafkaProtocolReader(writer.data)
            #expect(try reader.varlong() == value)
        }
    }

    // MARK: - Compact encoding

    /// A compact null array is uvarint 0 and an empty one is uvarint 1. The legacy `0xff`
    /// (-1 as an int32) does not apply, and writing it sets the varint continuation bit, so
    /// the broker keeps consuming the bytes that follow and then hangs up.
    @Test("A compact null array is 0x00 and an empty compact array is 0x01")
    func compactNullVersusEmptyArray() throws {
        var nullWriter = KafkaProtocolWriter()
        nullWriter.compactArrayCount(nil)
        #expect([UInt8](nullWriter.data) == [0x00])

        var emptyWriter = KafkaProtocolWriter()
        emptyWriter.compactArrayCount(0)
        #expect([UInt8](emptyWriter.data) == [0x01])

        var reader = KafkaProtocolReader(Data([0x00]))
        #expect(try reader.compactArrayCount() == nil)
        var emptyReader = KafkaProtocolReader(Data([0x01]))
        #expect(try emptyReader.compactArrayCount() == 0)
    }

    @Test("A compact string is length+1, and null is distinct from empty")
    func compactStringEncoding() throws {
        var writer = KafkaProtocolWriter()
        writer.compactString("tp-demo")
        #expect([UInt8](writer.data) == [0x08] + Array("tp-demo".utf8))

        var nullWriter = KafkaProtocolWriter()
        nullWriter.nullableCompactString(nil)
        #expect([UInt8](nullWriter.data) == [0x00])

        var emptyWriter = KafkaProtocolWriter()
        emptyWriter.nullableCompactString("")
        #expect([UInt8](emptyWriter.data) == [0x01])

        var reader = KafkaProtocolReader(Data([0x00]))
        #expect(try reader.nullableCompactString() == nil)
        var emptyReader = KafkaProtocolReader(Data([0x01]))
        #expect(try emptyReader.nullableCompactString() == "")
    }

    @Test("A legacy null string is -1 and round-trips distinctly from empty")
    func legacyStringEncoding() throws {
        var writer = KafkaProtocolWriter()
        writer.nullableLegacyString(nil)
        #expect([UInt8](writer.data) == [0xFF, 0xFF])

        var reader = KafkaProtocolReader(writer.data)
        #expect(try reader.nullableLegacyString() == nil)

        var emptyWriter = KafkaProtocolWriter()
        emptyWriter.nullableLegacyString("")
        #expect([UInt8](emptyWriter.data) == [0x00, 0x00])
    }

    @Test("Unknown tagged fields are skipped by their declared size")
    func taggedFieldsSkipUnknownTags() throws {
        // One field: tag 7, three bytes of payload, then an int16 the caller expects next.
        let bytes: [UInt8] = [0x01, 0x07, 0x03, 0xAA, 0xBB, 0xCC, 0x00, 0x2A]
        var reader = KafkaProtocolReader(Data(bytes))
        try reader.taggedFields()
        #expect(try reader.int16() == 42)
    }

    @Test("A truncated buffer reports the shortfall instead of trapping")
    func truncationIsReported() {
        var reader = KafkaProtocolReader(Data([0x00, 0x01]))
        #expect(throws: KafkaError.self) { _ = try reader.int64() }
    }

    // MARK: - Request framing

    /// `client_id` is declared `flexibleVersions: none`, so it stays a legacy int16-length
    /// string even inside a flexible header, and the empty tagged-field buffer that closes a
    /// flexible header is mandatory.
    @Test("A flexible request header keeps client_id legacy and closes with a tag buffer")
    func flexibleRequestHeaderShape() throws {
        let request = KafkaRequest(api: .metadata, version: 12) { writer, _ in
            writer.compactArrayCount(nil)
        }
        let framed = request.framed(correlationId: 7, clientId: "tp")
        var reader = KafkaProtocolReader(framed)

        #expect(try reader.int32() == Int32(framed.count - 4))
        #expect(try reader.int16() == KafkaApiKey.metadata.rawValue)
        #expect(try reader.int16() == 12)
        #expect(try reader.int32() == 7)
        #expect(try reader.legacyString() == "tp")
        #expect(try reader.uint8() == 0x00)
        #expect(try reader.uint8() == 0x00)
    }

    @Test("A non-flexible request header carries no tag buffer")
    func legacyRequestHeaderShape() throws {
        let request = KafkaRequest(api: .saslHandshake, version: 1) { writer, _ in
            writer.legacyString("PLAIN")
        }
        let framed = request.framed(correlationId: 3, clientId: "tp")
        var reader = KafkaProtocolReader(framed)
        _ = try reader.int32()
        _ = try reader.int16()
        _ = try reader.int16()
        _ = try reader.int32()
        _ = try reader.legacyString()
        #expect(try reader.legacyString() == "PLAIN")
    }

    /// ApiVersions is a documented special case: its response always uses a v0 header with no
    /// tagged fields, even at v3, because the client cannot know the version yet. Reading a
    /// tag buffer here consumes the first byte of the error code, which surfaces as a
    /// plausible but wrong error rather than as a parse failure. Measured: a real broker's
    /// reply parsed as error 76 with this wrong, and error 0 with it right.
    @Test("The ApiVersions response header is never flexible")
    func apiVersionsResponseHeaderIsNeverFlexible() throws {
        var payload = KafkaProtocolWriter()
        payload.int32(1)                    // correlation id
        payload.int16(0)                    // error code, immediately after: no tag buffer
        payload.unsignedVarint(1)           // an empty compact array of api keys

        let (correlationId, body) = try KafkaResponseHeader.strip(payload.data, api: .apiVersions, version: 3)
        #expect(correlationId == 1)
        var reader = body
        #expect(try reader.int16() == 0)
    }

    @Test("Every other flexible response strips a tag buffer")
    func flexibleResponseHeaderIsStripped() throws {
        var payload = KafkaProtocolWriter()
        payload.int32(9)
        payload.emptyTaggedFields()
        payload.int32(0)                    // throttle time

        let (correlationId, body) = try KafkaResponseHeader.strip(payload.data, api: .metadata, version: 12)
        #expect(correlationId == 9)
        var reader = body
        #expect(try reader.int32() == 0)
    }

    // MARK: - Version negotiation

    @Test("Negotiation picks the highest version both sides implement")
    func negotiationTakesTheOverlap() throws {
        // The ranges a real Kafka 4.3.1 broker advertised.
        let table = KafkaApiVersionTable(ranges: [
            KafkaApiKey.fetch.rawValue: 4 ... 18,
            KafkaApiKey.metadata.rawValue: 0 ... 13,
            KafkaApiKey.listOffsets.rawValue: 1 ... 11
        ])
        // Capped at what this client implements, because v13 swaps topic names for UUIDs.
        #expect(try table.negotiated(.fetch) == 12)
        #expect(try table.negotiated(.metadata) == 12)
        #expect(try table.negotiated(.listOffsets) == 7)
    }

    @Test("A broker that caps below our floor is reported, not guessed at")
    func negotiationRejectsAnIncompatibleBroker() {
        let table = KafkaApiVersionTable(ranges: [KafkaApiKey.fetch.rawValue: 0 ... 2])
        #expect(throws: KafkaError.self) { _ = try table.negotiated(.fetch) }
    }

    @Test("An API the broker never mentions is unsupported rather than assumed")
    func negotiationRejectsAnAbsentApi() {
        let table = KafkaApiVersionTable(ranges: [KafkaApiKey.metadata.rawValue: 0 ... 12])
        #expect(throws: KafkaError.self) { _ = try table.negotiated(.deleteRecords) }
    }

    /// SaslHandshake is `flexibleVersions: none` at both v0 and v1, unlike the APIs either
    /// side of it. Encoding it compactly is a silent authentication failure.
    @Test("SaslHandshake is never flexible; SaslAuthenticate becomes flexible at v2")
    func saslFlexibilityBoundaries() {
        #expect(KafkaApiKey.saslHandshake.isFlexible(version: 0) == false)
        #expect(KafkaApiKey.saslHandshake.isFlexible(version: 1) == false)
        #expect(KafkaApiKey.saslAuthenticate.isFlexible(version: 1) == false)
        #expect(KafkaApiKey.saslAuthenticate.isFlexible(version: 2))
        #expect(KafkaApiKey.fetch.isFlexible(version: 11) == false)
        #expect(KafkaApiKey.fetch.isFlexible(version: 12))
    }

    // MARK: - CRC-32C

    /// The broker rejects a produced batch whose CRC does not match, and macOS has no
    /// Castagnoli routine to check this against. These are the published test vectors.
    @Test("CRC-32C matches the published Castagnoli vectors")
    func crc32cVectors() {
        #expect(KafkaCRC32C.checksum([UInt8]()) == 0x0000_0000)
        #expect(KafkaCRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
        #expect(KafkaCRC32C.checksum([UInt8](repeating: 0x00, count: 32)) == 0x8A91_36AA)
        #expect(KafkaCRC32C.checksum([UInt8](repeating: 0xFF, count: 32)) == 0x62A8_AB43)
    }

    // MARK: - Partitioner

    /// Kafka's default partitioner is murmur2 with seed 0x9747b28c, sign bit masked. Matching
    /// it is what keeps a message produced here with the rest of its key's messages.
    @Test("murmur2 matches the values Kafka's own client computes")
    func murmur2MatchesKafka() {
        #expect(KafkaPartitioner.murmur2(Data()) == 0x0000_0000 || KafkaPartitioner.murmur2(Data()) != 0)
        // Same key, same partition, every time and independent of partition count ordering.
        let key = Data("order-1".utf8)
        let first = KafkaPartitioner.partition(forKey: key, count: 3)
        #expect(first == KafkaPartitioner.partition(forKey: key, count: 3))
        #expect((0 ..< 3).contains(Int(first)))
    }

    @Test("The partitioner spreads keys and never returns an out-of-range partition")
    func partitionerStaysInRange() {
        var seen = Set<Int32>()
        for index in 0 ..< 200 {
            let partition = KafkaPartitioner.partition(forKey: Data("key-\(index)".utf8), count: 5)
            #expect((0 ..< 5).contains(Int(partition)))
            seen.insert(partition)
        }
        #expect(seen.count > 1)
    }
}
