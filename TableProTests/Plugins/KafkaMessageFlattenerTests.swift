import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Kafka message flattener")
struct KafkaMessageFlattenerTests {
    private func record(
        partition: Int32 = 0,
        offset: Int64 = 0,
        timestamp: Int64 = 1_787_709_624_571,
        key: Data? = nil,
        value: Data? = nil,
        headers: [KafkaRecordHeader] = []
    ) -> KafkaRecord {
        KafkaRecord(
            offset: offset,
            timestamp: timestamp,
            timestampIsLogAppendTime: false,
            key: key,
            value: value,
            headers: headers,
            partition: partition
        )
    }

    /// The column order is the one every Kafka UI converged on: coordinates, then payload.
    @Test("The column set and its order are the Kafka convention")
    func columnOrder() {
        let columns = KafkaMessageFlattener.columns(for: [])
        #expect(columns.map(\.name) == [
            "partition", "offset", "timestamp", "key", "value", "headers", "key_size", "value_size"
        ])
    }

    /// The host runs blob formatting over a cell whenever its COLUMN is typed binary, so a
    /// text value inside a BLOB column renders as hex. Deciding the type once per page is what
    /// keeps the cell kind and the column type agreeing.
    @Test("A page of UTF-8 payloads types its key and value columns TEXT")
    func textPayloadsTypeAsText() {
        let records = [
            record(key: Data("k1".utf8), value: Data("{\"a\":1}".utf8)),
            record(key: Data("k2".utf8), value: Data("plain".utf8))
        ]
        let columns = KafkaMessageFlattener.columns(for: records)
        #expect(columns.first { $0.name == "key" }?.dataType == "TEXT")
        #expect(columns.first { $0.name == "value" }?.dataType == "TEXT")

        let rows = KafkaMessageFlattener.rows(for: records)
        #expect(rows[0][4] == .text("{\"a\":1}"))
    }

    @Test("One non-UTF-8 payload types the whole column BLOB")
    func binaryPayloadTypesAsBlob() {
        let records = [
            record(value: Data("fine".utf8)),
            record(value: Data([0xFF, 0xFE, 0x00, 0x01]))
        ]
        let columns = KafkaMessageFlattener.columns(for: records)
        #expect(columns.first { $0.name == "value" }?.dataType == "BLOB")

        let rows = KafkaMessageFlattener.rows(for: records)
        #expect(rows[1][4] == .bytes(Data([0xFF, 0xFE, 0x00, 0x01])))
        // The valid payload stays bytes too, so the column's type is true of every cell in it.
        #expect(rows[0][4] == .bytes(Data("fine".utf8)))
    }

    /// A tombstone and an empty message mean different things on a compacted topic, so they
    /// must not both render as blank.
    @Test("A null value is null, and an empty value is empty")
    func nullVersusEmpty() {
        let rows = KafkaMessageFlattener.rows(for: [
            record(key: Data("k".utf8), value: nil),
            record(key: Data("k".utf8), value: Data())
        ])
        #expect(rows[0][4] == .null)
        #expect(rows[1][4] == .text(""))
    }

    @Test("Sizes count bytes, and a null payload counts zero")
    func sizes() {
        let rows = KafkaMessageFlattener.rows(for: [
            record(key: Data("abc".utf8), value: Data("hello".utf8)),
            record(key: nil, value: nil)
        ])
        #expect(rows[0][6] == .text("3"))
        #expect(rows[0][7] == .text("5"))
        #expect(rows[1][6] == .text("0"))
        #expect(rows[1][7] == .text("0"))
    }

    @Test("Headers render as a JSON object, and no headers renders as null")
    func headers() {
        let rows = KafkaMessageFlattener.rows(for: [
            record(headers: [
                KafkaRecordHeader(key: "trace", value: Data("abc".utf8)),
                KafkaRecordHeader(key: "retry", value: nil)
            ]),
            record(headers: [])
        ])
        #expect(rows[0][5] == .text("{\"trace\":\"abc\",\"retry\":null}"))
        #expect(rows[1][5] == .null)
    }

    @Test("A header value containing a quote is escaped rather than breaking the JSON")
    func headerEscaping() {
        let rows = KafkaMessageFlattener.rows(for: [
            record(headers: [KafkaRecordHeader(key: "q", value: Data("a\"b".utf8))])
        ])
        #expect(rows[0][5] == .text("{\"q\":\"a\\\"b\"}"))
    }

    @Test("Coordinates render as their own values")
    func coordinates() {
        let rows = KafkaMessageFlattener.rows(for: [record(partition: 7, offset: 12_345)])
        #expect(rows[0][0] == .text("7"))
        #expect(rows[0][1] == .text("12345"))
    }

    /// A producer that sets no timestamp writes -1, and rendering that as a 1969 date would be
    /// a fabricated fact.
    @Test("A missing timestamp renders empty rather than as an epoch date")
    func missingTimestamp() {
        #expect(KafkaMessageFlattener.formatTimestamp(-1) == "")
        #expect(KafkaMessageFlattener.formatTimestamp(0) == "")
    }

    /// The timestamp is formatted by arithmetic rather than by ISO8601DateFormatter, because a
    /// formatter is not Sendable and building one per row is most of the cost of a page. These
    /// pin the arithmetic against instants computed independently.
    @Test("Timestamps format as UTC ISO 8601 with milliseconds")
    func timestampFormatting() {
        #expect(KafkaMessageFlattener.formatTimestamp(1) == "1970-01-01T00:00:00.001Z")
        #expect(KafkaMessageFlattener.formatTimestamp(1_000) == "1970-01-01T00:00:01.000Z")
        #expect(KafkaMessageFlattener.formatTimestamp(86_399_000) == "1970-01-01T23:59:59.000Z")
        #expect(KafkaMessageFlattener.formatTimestamp(86_400_000) == "1970-01-02T00:00:00.000Z")
        // A leap day, and the century rule either side of it.
        #expect(KafkaMessageFlattener.formatTimestamp(951_782_400_000) == "2000-02-29T00:00:00.000Z")
        #expect(KafkaMessageFlattener.formatTimestamp(1_709_164_800_000) == "2024-02-29T00:00:00.000Z")
        #expect(KafkaMessageFlattener.formatTimestamp(1_787_709_624_571) == "2026-08-26T02:00:24.571Z")
    }

    /// The same instants, cross-checked against Foundation so the hand-rolled civil-date
    /// conversion cannot drift from the calendar everything else uses.
    @Test("The arithmetic formatter agrees with Foundation across a wide range")
    func timestampMatchesFoundation() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")

        for milliseconds in stride(from: Int64(1), through: 2_100_000_000_000, by: 37_913_141_593) {
            let expected = formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
            #expect(
                KafkaMessageFlattener.formatTimestamp(milliseconds) == expected,
                "disagreed at \(milliseconds)"
            )
        }
    }
}

@Suite("Kafka browse merge")
struct KafkaBrowseMergeTests {
    private func record(partition: Int32, offset: Int64, timestamp: Int64) -> KafkaRecord {
        KafkaRecord(
            offset: offset,
            timestamp: timestamp,
            timestampIsLogAppendTime: false,
            key: nil,
            value: nil,
            headers: [],
            partition: partition
        )
    }

    /// Kafka guarantees order only within a partition, so the cross-partition order is a
    /// presentation choice. It has to be total and stable, or paging repeats or skips a row.
    @Test("Merged records order by timestamp, then partition, then offset")
    func mergeOrder() {
        let merged = KafkaRecordOrdering.merge([
            record(partition: 1, offset: 5, timestamp: 300),
            record(partition: 0, offset: 9, timestamp: 100),
            record(partition: 2, offset: 1, timestamp: 200),
            record(partition: 0, offset: 10, timestamp: 200)
        ])
        #expect(merged.map(\.timestamp) == [100, 200, 200, 300])
        // The tie at 200 breaks on partition, so partition 0 precedes partition 2.
        #expect(merged[1].partition == 0)
        #expect(merged[2].partition == 2)
    }

    @Test("Records sharing a timestamp and a partition order by offset")
    func offsetBreaksTheFinalTie() {
        let merged = KafkaRecordOrdering.merge([
            record(partition: 0, offset: 3, timestamp: 100),
            record(partition: 0, offset: 1, timestamp: 100),
            record(partition: 0, offset: 2, timestamp: 100)
        ])
        #expect(merged.map(\.offset) == [1, 2, 3])
    }

    /// Every (partition, offset) is unique in a merged page, which is what lets paging resume
    /// without repeating or dropping a message.
    @Test("A merged page never repeats a (partition, offset) pair")
    func coordinatesStayUnique() {
        let merged = KafkaRecordOrdering.merge((0 ..< 30).map { index in
            record(partition: Int32(index % 3), offset: Int64(index / 3), timestamp: Int64(index % 7))
        })
        var seen = Set<String>()
        for item in merged {
            let key = "\(item.partition):\(item.offset)"
            #expect(seen.contains(key) == false)
            seen.insert(key)
        }
        #expect(seen.count == 30)
    }
}
