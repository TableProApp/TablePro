import Foundation
import TableProPluginKit

/// Turns Kafka messages into grid rows.
///
/// The column set and its order follow what every Kafka UI converged on (kafbat's messages
/// table, Redpanda Console's column settings, AKHQ): the coordinates first, then the payload.
enum KafkaMessageFlattener {
    /// Whether a page's key and value columns are text, decided once and then used by both
    /// `columns` and `rows` so the page is not UTF-8 validated twice over.
    struct PayloadKinds: Sendable {
        let keyIsText: Bool
        let valueIsText: Bool
    }

    static let partitionColumn = "partition"
    static let offsetColumn = "offset"
    static let timestampColumn = "timestamp"
    static let keyColumn = "key"
    static let valueColumn = "value"
    static let headersColumn = "headers"
    static let keySizeColumn = "key_size"
    static let valueSizeColumn = "value_size"

    /// A Kafka payload is bytes with no declared type, so the column type is decided per page
    /// from the page's own contents rather than per value.
    ///
    /// That distinction is load-bearing and TablePro has been bitten by it before: the host
    /// runs blob formatting over a cell whenever its COLUMN is typed binary, so one text value
    /// inside a column typed BLOB renders as hex, and one binary value inside a column typed
    /// TEXT escapes into the inline editor. Deciding once per page keeps the cell kind and the
    /// column type agreeing.
    static func payloadKinds(for records: [KafkaRecord]) -> PayloadKinds {
        PayloadKinds(
            keyIsText: allDecodeAsText(records.lazy.map(\.key)),
            valueIsText: allDecodeAsText(records.lazy.map(\.value))
        )
    }

    static func columns(for records: [KafkaRecord]) -> [PluginColumnInfo] {
        columns(kinds: payloadKinds(for: records))
    }

    static func columns(kinds: PayloadKinds) -> [PluginColumnInfo] {
        let keyIsText = kinds.keyIsText
        let valueIsText = kinds.valueIsText
        return [
            PluginColumnInfo(name: partitionColumn, dataType: "INTEGER", isNullable: false),
            PluginColumnInfo(name: offsetColumn, dataType: "BIGINT", isNullable: false),
            PluginColumnInfo(name: timestampColumn, dataType: "TIMESTAMP", isNullable: false),
            PluginColumnInfo(name: keyColumn, dataType: keyIsText ? "TEXT" : "BLOB", isNullable: true),
            PluginColumnInfo(name: valueColumn, dataType: valueIsText ? "TEXT" : "BLOB", isNullable: true),
            PluginColumnInfo(name: headersColumn, dataType: "JSON", isNullable: true),
            PluginColumnInfo(name: keySizeColumn, dataType: "INTEGER", isNullable: false),
            PluginColumnInfo(name: valueSizeColumn, dataType: "INTEGER", isNullable: false)
        ]
    }

    static func rows(for records: [KafkaRecord]) -> [[PluginCellValue]] {
        rows(for: records, kinds: payloadKinds(for: records))
    }

    static func rows(for records: [KafkaRecord], kinds: PayloadKinds) -> [[PluginCellValue]] {
        let keyIsText = kinds.keyIsText
        let valueIsText = kinds.valueIsText
        return records.map { record in
            [
                .text(String(record.partition)),
                .text(String(record.offset)),
                .text(formatTimestamp(record.timestamp)),
                payload(record.key, asText: keyIsText),
                payload(record.value, asText: valueIsText),
                headers(record.headers),
                .text(String(record.key?.count ?? 0)),
                .text(String(record.value?.count ?? 0))
            ]
        }
    }

    /// A null value is a tombstone and a zero-length value is an empty message. They mean
    /// different things on a compacted topic, so they must not both render as blank.
    private static func payload(_ data: Data?, asText: Bool) -> PluginCellValue {
        guard let data else { return .null }
        guard asText else { return .bytes(data) }
        guard let text = String(data: data, encoding: .utf8) else { return .bytes(data) }
        return .text(text)
    }

    private static func headers(_ headers: [KafkaRecordHeader]) -> PluginCellValue {
        guard !headers.isEmpty else { return .null }
        let pairs = headers.map { header -> String in
            let value = header.value.flatMap { String(data: $0, encoding: .utf8) } ?? header.value?.hexString
            return "\(jsonString(header.key)):\(value.map(jsonString) ?? "null")"
        }
        return .text("{\(pairs.joined(separator: ","))}")
    }

    /// A column is text only if every non-null payload on the page decodes as UTF-8. One
    /// binary value is enough to make the whole column binary, because rendering a binary
    /// payload through a text column is the lossier of the two mistakes.
    private static func allDecodeAsText<S: Sequence>(_ payloads: S) -> Bool where S.Element == Data? {
        for case let payload? in payloads where String(data: payload, encoding: .utf8) == nil {
            return false
        }
        return true
    }

    /// Kafka timestamps are milliseconds since the epoch, always UTC. -1 means the producer
    /// set none.
    ///
    /// Formatted by arithmetic rather than by `ISO8601DateFormatter`. A formatter is not
    /// `Sendable`, so under Swift 6 it cannot be a shared `static let`, and building one per
    /// row is most of the cost of rendering a page. The civil-date conversion below is exact
    /// for the whole range Kafka can express.
    static func formatTimestamp(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "" }
        let totalSeconds = milliseconds / 1_000
        let millisecondPart = Int(milliseconds % 1_000)
        var secondOfDay = Int(totalSeconds % 86_400)
        var days = totalSeconds / 86_400
        if secondOfDay < 0 {
            secondOfDay += 86_400
            days -= 1
        }
        let (year, month, day) = civilDate(fromDaysSinceEpoch: days)
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
            + "T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
            + ".\(pad(millisecondPart, 3))Z"
    }

    /// Howard Hinnant's days-from-civil, inverted. Exact for every representable day, with no
    /// lookup table and no leap-year special cases beyond the shifted-era arithmetic.
    private static func civilDate(fromDaysSinceEpoch days: Int64) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (Int(month <= 2 ? year + 1 : year), Int(month), Int(day))
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    private static func jsonString(_ value: String) -> String {
        var escaped = ""
        for character in value.unicodeScalars {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if character.value < 0x20 {
                    escaped += String(format: "\\u%04x", character.value)
                } else {
                    escaped.unicodeScalars.append(character)
                }
            }
        }
        return "\"\(escaped)\""
    }
}
