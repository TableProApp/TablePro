import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Record batch decoding, against batches built the way a broker builds them.
@Suite("Kafka record batch")
struct KafkaRecordBatchTests {
    /// Builds an uncompressed v2 batch the way `KafkaRecordBatchEncoder` does, but with an
    /// arbitrary record count, so the decoder is exercised against multi-record batches.
    private static func batch(
        baseOffset: Int64,
        baseTimestamp: Int64,
        records: [(key: Data?, value: Data?, headers: [KafkaRecordHeader])],
        attributes: Int16 = 0,
        producerId: Int64 = -1
    ) -> Data {
        var payload = KafkaProtocolWriter()
        for (index, record) in records.enumerated() {
            var inner = KafkaProtocolWriter()
            inner.int8(0)
            inner.varlong(Int64(index))
            inner.varint(Int32(index))
            if let key = record.key {
                inner.varint(Int32(key.count))
                inner.raw(key)
            } else {
                inner.varint(-1)
            }
            if let value = record.value {
                inner.varint(Int32(value.count))
                inner.raw(value)
            } else {
                inner.varint(-1)
            }
            inner.varint(Int32(record.headers.count))
            for header in record.headers {
                let keyBytes = Data(header.key.utf8)
                inner.varint(Int32(keyBytes.count))
                inner.raw(keyBytes)
                if let value = header.value {
                    inner.varint(Int32(value.count))
                    inner.raw(value)
                } else {
                    inner.varint(-1)
                }
            }
            payload.varint(Int32(inner.count))
            payload.raw(inner.bytes)
        }

        var body = KafkaProtocolWriter()
        body.int16(attributes)
        body.int32(Int32(max(0, records.count - 1)))
        body.int64(baseTimestamp)
        body.int64(baseTimestamp)
        body.int64(producerId)
        body.int16(-1)
        body.int32(-1)
        body.int32(Int32(records.count))
        body.raw(payload.bytes)

        var afterLength = KafkaProtocolWriter()
        afterLength.int32(-1)
        afterLength.int8(2)
        afterLength.uint32(KafkaCRC32C.checksum(body.bytes))
        afterLength.raw(body.bytes)

        var framed = KafkaProtocolWriter()
        framed.int64(baseOffset)
        framed.int32(Int32(afterLength.count))
        framed.raw(afterLength.bytes)
        return framed.data
    }

    @Test("Records decode with their offsets, timestamps, keys, values and headers")
    func decodesAFullBatch() throws {
        let blob = Self.batch(
            baseOffset: 100,
            baseTimestamp: 1_787_709_624_571,
            records: [
                (Data("k1".utf8), Data("v1".utf8), []),
                (Data("k2".utf8), Data("v2".utf8), [KafkaRecordHeader(key: "trace", value: Data("abc".utf8))])
            ]
        )

        let decoded = try KafkaRecordBatchDecoder.decode(blob: blob, partition: 3, skipAborted: true)
        #expect(decoded.records.count == 2)
        #expect(decoded.truncated == false)

        let first = decoded.records[0]
        #expect(first.offset == 100)
        #expect(first.partition == 3)
        #expect(first.timestamp == 1_787_709_624_571)
        #expect(first.key == Data("k1".utf8))
        #expect(first.value == Data("v1".utf8))

        let second = decoded.records[1]
        #expect(second.offset == 101)
        #expect(second.timestamp == 1_787_709_624_572)
        #expect(second.headers.count == 1)
        #expect(second.headers[0].key == "trace")
        #expect(second.headers[0].value == Data("abc".utf8))
    }

    /// A null value is a tombstone on a compacted topic and a zero-length value is an empty
    /// message. Collapsing them loses the distinction the topic exists to express.
    @Test("A null key or value stays null and does not become empty")
    func nullIsNotEmpty() throws {
        let blob = Self.batch(
            baseOffset: 0,
            baseTimestamp: 1_000,
            records: [
                (nil, nil, []),
                (Data(), Data(), [])
            ]
        )
        let decoded = try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true)
        #expect(decoded.records[0].key == nil)
        #expect(decoded.records[0].value == nil)
        #expect(decoded.records[1].key == Data())
        #expect(decoded.records[1].value == Data())
    }

    /// A partition's blob holds a SEQUENCE of batches, not one, and the broker truncates it at
    /// the byte budget mid-batch. Treating the tail as corruption would drop a whole page.
    @Test("Several batches in one blob all decode, in order")
    func decodesConsecutiveBatches() throws {
        var blob = Self.batch(baseOffset: 0, baseTimestamp: 1_000, records: [(nil, Data("a".utf8), [])])
        blob.append(Self.batch(baseOffset: 1, baseTimestamp: 2_000, records: [(nil, Data("b".utf8), [])]))
        blob.append(Self.batch(baseOffset: 2, baseTimestamp: 3_000, records: [(nil, Data("c".utf8), [])]))

        let decoded = try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true)
        #expect(decoded.records.map(\.offset) == [0, 1, 2])
        #expect(decoded.records.compactMap { $0.value.flatMap { String(data: $0, encoding: .utf8) } } == ["a", "b", "c"])
        #expect(decoded.truncated == false)
    }

    @Test("A partial trailing batch is dropped and reported as truncation")
    func partialTrailingBatchIsDropped() throws {
        var blob = Self.batch(baseOffset: 0, baseTimestamp: 1_000, records: [(nil, Data("a".utf8), [])])
        let second = Self.batch(baseOffset: 1, baseTimestamp: 2_000, records: [(nil, Data("b".utf8), [])])
        blob.append(second.prefix(second.count - 5))

        let decoded = try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true)
        #expect(decoded.records.map(\.offset) == [0])
        #expect(decoded.truncated)
    }

    /// Control batches carry a transaction's commit and abort markers. They are records, so a
    /// decoder that does not know about attribute bit 5 puts marker rows in the user's grid.
    /// A partition can carry several producers at once. Matching an aborted run on its offset
    /// alone let one producer's commit marker end another producer's run, and the rolled-back
    /// records then reached the grid.
    @Test("An aborted run ends only for the producer that opened it")
    func abortedRunsAreTrackedPerProducer() throws {
        // Producer 7 opens an aborted transaction at offset 0.
        var blob = Self.batch(
            baseOffset: 0,
            baseTimestamp: 1_000,
            records: [(nil, Data("rolled-back".utf8), [])],
            attributes: 0x10,
            producerId: 7
        )
        // Producer 9 commits in the middle. This must not release producer 7's run.
        blob.append(Self.batch(
            baseOffset: 1,
            baseTimestamp: 1_100,
            records: [(Data([0, 0, 0, 0]), Data([0, 0]), [])],
            attributes: 0x20,
            producerId: 9
        ))
        // Still producer 7, still inside the aborted run.
        blob.append(Self.batch(
            baseOffset: 2,
            baseTimestamp: 1_200,
            records: [(nil, Data("also-rolled-back".utf8), [])],
            attributes: 0x10,
            producerId: 7
        ))

        let decoded = try KafkaRecordBatchDecoder.decode(
            blob: blob,
            partition: 0,
            abortedTransactions: [KafkaAbortedTransaction(producerId: 7, firstOffset: 0)],
            skipAborted: true
        )
        #expect(decoded.records.isEmpty)
    }

    @Test("A batch claiming a length shorter than its own header is dropped, not decoded")
    func impossibleBatchLengthIsDropped() throws {
        var writer = KafkaProtocolWriter()
        writer.int64(0)
        writer.int32(0)                                      // a length that ends before the header
        writer.raw([UInt8](repeating: 0, count: 80))
        let decoded = try KafkaRecordBatchDecoder.decode(blob: writer.data, partition: 0, skipAborted: true)
        #expect(decoded.records.isEmpty)
        #expect(decoded.truncated)
    }

    @Test("Control batches never produce rows")
    func controlBatchesAreSkipped() throws {
        var blob = Self.batch(baseOffset: 0, baseTimestamp: 1_000, records: [(nil, Data("real".utf8), [])])
        blob.append(Self.batch(
            baseOffset: 1,
            baseTimestamp: 2_000,
            records: [(Data([0, 0, 0, 0]), Data([0, 0]), [])],
            attributes: 0x20,
            producerId: 42
        ))

        let decoded = try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true)
        #expect(decoded.records.count == 1)
        #expect(decoded.records[0].value == Data("real".utf8))
    }

    @Test("An unknown magic byte is reported rather than guessed at")
    func rejectsLegacyMagic() {
        var writer = KafkaProtocolWriter()
        writer.int64(0)
        writer.int32(49)
        writer.int32(-1)
        writer.int8(1)                                       // v1 message set, not supported
        writer.raw([UInt8](repeating: 0, count: 60))

        #expect(throws: KafkaError.self) {
            _ = try KafkaRecordBatchDecoder.decode(blob: writer.data, partition: 0, skipAborted: true)
        }
    }

    @Test("An empty blob decodes to nothing rather than failing")
    func emptyBlobIsNotAnError() throws {
        let decoded = try KafkaRecordBatchDecoder.decode(blob: Data(), partition: 0, skipAborted: true)
        #expect(decoded.records.isEmpty)
        #expect(decoded.truncated == false)
    }

    /// The produced batch is the one path where the CRC matters: a broker rejects a mismatch
    /// with CORRUPT_MESSAGE, so the encoder has to agree with the decoder byte for byte.
    @Test("An encoded single-record batch round-trips and carries a valid CRC")
    func encodedBatchRoundTrips() throws {
        let encoded = KafkaRecordBatchEncoder.singleRecordBatch(
            key: Data("order-1".utf8),
            value: Data("{\"id\":1}".utf8),
            headers: [KafkaRecordHeader(key: "source", value: Data("tablepro".utf8))],
            timestamp: 1_787_709_624_571
        )

        var reader = KafkaProtocolReader(encoded)
        _ = try reader.int64()
        let length = Int(try reader.int32())
        _ = try reader.int32()
        _ = try reader.int8()
        let storedCRC = try reader.uint32()
        let bodyStart = reader.offset
        let bodyLength = length - (bodyStart - 12)
        let body = [UInt8](encoded)[bodyStart ..< bodyStart + bodyLength]
        #expect(KafkaCRC32C.checksum(body) == storedCRC)

        let decoded = try KafkaRecordBatchDecoder.decode(blob: encoded, partition: 0, skipAborted: true)
        #expect(decoded.records.count == 1)
        #expect(decoded.records[0].key == Data("order-1".utf8))
        #expect(decoded.records[0].value == Data("{\"id\":1}".utf8))
        #expect(decoded.records[0].headers.first?.key == "source")
        #expect(decoded.records[0].timestamp == 1_787_709_624_571)
    }

    @Test("A produced tombstone keeps its null value through the round trip")
    func encodedTombstoneRoundTrips() throws {
        let encoded = KafkaRecordBatchEncoder.singleRecordBatch(
            key: Data("gone".utf8),
            value: nil,
            headers: [],
            timestamp: 1_000
        )
        let decoded = try KafkaRecordBatchDecoder.decode(blob: encoded, partition: 0, skipAborted: true)
        #expect(decoded.records[0].value == nil)
        #expect(decoded.records[0].key == Data("gone".utf8))
    }
}
