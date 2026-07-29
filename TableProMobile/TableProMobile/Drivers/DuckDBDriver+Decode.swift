import CDuckDB
import Foundation
import TableProModels

extension DuckDBActor {
    static func decodeCell(vector: duckdb_vector, row: idx_t, column: DuckDBStreamColumn, options: StreamOptions) -> Cell {
        if let validity = duckdb_vector_get_validity(vector), !duckdb_validity_row_is_valid(validity, row) {
            return .null
        }
        guard let data = duckdb_vector_get_data(vector) else { return .null }

        if column.castToText {
            return decodeVarchar(data, row: row, options: options)
        }

        switch column.type {
        case DUCKDB_TYPE_VARCHAR:
            return decodeVarchar(data, row: row, options: options)
        case DUCKDB_TYPE_BLOB:
            return decodeBlob(data, row: row)
        case DUCKDB_TYPE_BOOLEAN:
            return .text(data.load(fromByteOffset: Int(row) * MemoryLayout<Bool>.stride, as: Bool.self) ? "true" : "false")
        case DUCKDB_TYPE_TINYINT:
            return .text(String(element(data, row, Int8.self)))
        case DUCKDB_TYPE_SMALLINT:
            return .text(String(element(data, row, Int16.self)))
        case DUCKDB_TYPE_INTEGER:
            return .text(String(element(data, row, Int32.self)))
        case DUCKDB_TYPE_BIGINT:
            return .text(String(element(data, row, Int64.self)))
        case DUCKDB_TYPE_UTINYINT:
            return .text(String(element(data, row, UInt8.self)))
        case DUCKDB_TYPE_USMALLINT:
            return .text(String(element(data, row, UInt16.self)))
        case DUCKDB_TYPE_UINTEGER:
            return .text(String(element(data, row, UInt32.self)))
        case DUCKDB_TYPE_UBIGINT:
            return .text(String(element(data, row, UInt64.self)))
        case DUCKDB_TYPE_FLOAT:
            return .text(String(element(data, row, Float.self)))
        case DUCKDB_TYPE_DOUBLE:
            return .text(String(element(data, row, Double.self)))
        case DUCKDB_TYPE_HUGEINT:
            let value = element(data, row, duckdb_hugeint.self)
            return .text(HugeIntFormatter.format(upper: value.upper, lower: value.lower))
        case DUCKDB_TYPE_UHUGEINT:
            let value = element(data, row, duckdb_uhugeint.self)
            return .text(HugeIntFormatter.formatUnsigned(upper: value.upper, lower: value.lower))
        case DUCKDB_TYPE_UUID:
            let value = element(data, row, duckdb_hugeint.self)
            return .text(formatUUID(value))
        case DUCKDB_TYPE_DATE:
            let value = element(data, row, duckdb_date.self)
            return .text(formatDate(duckdb_from_date(value)))
        case DUCKDB_TYPE_TIME:
            let value = element(data, row, duckdb_time.self)
            return .text(formatTime(duckdb_from_time(value)))
        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_S, DUCKDB_TYPE_TIMESTAMP_MS, DUCKDB_TYPE_TIMESTAMP_NS:
            return .text(formatTimestamp(normalizedTimestamp(data, row: row, type: column.type)))
        default:
            return decodeVarchar(data, row: row, options: options)
        }
    }

    private static func element<T>(_ data: UnsafeMutableRawPointer, _ row: idx_t, _ type: T.Type) -> T {
        data.load(fromByteOffset: Int(row) * MemoryLayout<T>.stride, as: T.self)
    }

    private static func decodeVarchar(_ data: UnsafeMutableRawPointer, row: idx_t, options: StreamOptions) -> Cell {
        let strings = data.assumingMemoryBound(to: duckdb_string_t.self)
        var value = strings[Int(row)]
        let length = Int(duckdb_string_t_length(value))
        guard length > 0, let pointer = duckdb_string_t_data(&value) else { return .text("") }
        let text = String(bytes: UnsafeRawBufferPointer(start: pointer, count: length), encoding: .utf8) ?? ""
        if length > options.textTruncationBytes {
            let prefix = String(text.prefix(options.textTruncationBytes))
            return .truncatedText(prefix: prefix, totalBytes: length, ref: nil)
        }
        return .text(text)
    }

    private static func decodeBlob(_ data: UnsafeMutableRawPointer, row: idx_t) -> Cell {
        let strings = data.assumingMemoryBound(to: duckdb_string_t.self)
        var value = strings[Int(row)]
        let length = Int(duckdb_string_t_length(value))
        guard length > 0, let pointer = duckdb_string_t_data(&value) else { return .text("") }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        return .text(Data(bytes).base64EncodedString())
    }

    private static func normalizedTimestamp(_ data: UnsafeMutableRawPointer, row: idx_t, type: duckdb_type) -> duckdb_timestamp {
        let raw = element(data, row, duckdb_timestamp.self).micros
        switch type {
        case DUCKDB_TYPE_TIMESTAMP_S:
            return duckdb_timestamp(micros: raw * 1_000_000)
        case DUCKDB_TYPE_TIMESTAMP_MS:
            return duckdb_timestamp(micros: raw * 1_000)
        case DUCKDB_TYPE_TIMESTAMP_NS:
            return duckdb_timestamp(micros: raw / 1_000)
        default:
            return duckdb_timestamp(micros: raw)
        }
    }

    // MARK: - Formatting (matches duckdb_value_varchar output)

    static func formatTimestamp(_ ts: duckdb_timestamp) -> String {
        let parts = duckdb_from_timestamp(ts)
        let date = parts.date
        let time = parts.time
        let micros = time.micros % 1_000_000
        let year = formatYearISO(date.year)
        if micros == 0 {
            return String(format: "\(year)-%02d-%02d %02d:%02d:%02d", date.month, date.day, time.hour, time.min, time.sec)
        }
        return String(format: "\(year)-%02d-%02d %02d:%02d:%02d.%06d", date.month, date.day, time.hour, time.min, time.sec, micros)
    }

    static func formatDate(_ date: duckdb_date_struct) -> String {
        String(format: "\(formatYearISO(date.year))-%02d-%02d", date.month, date.day)
    }

    static func formatTime(_ time: duckdb_time_struct) -> String {
        let micros = time.micros % 1_000_000
        if micros == 0 {
            return String(format: "%02d:%02d:%02d", time.hour, time.min, time.sec)
        }
        return String(format: "%02d:%02d:%02d.%06d", time.hour, time.min, time.sec, micros)
    }

    static func formatYearISO(_ year: Int32) -> String {
        year < 0 ? String(format: "-%04d", -Int(year)) : String(format: "%04d", year)
    }

    static func formatUUID(_ value: duckdb_hugeint) -> String {
        let high = UInt64(bitPattern: value.upper) ^ 0x8000_0000_0000_0000
        let low = value.lower
        let hex = String(format: "%016llx%016llx", high, low)
        let s = Array(hex)
        return "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
    }

    // Single source of truth for which types decodeCell handles directly from
    // vector data. Anything not in this allowlist is cast to VARCHAR in the
    // query (requiresTextCast), so an unhandled or future type can never reach
    // the native decode path and reinterpret non-string bytes as a string.
    static func isNativelyDecodable(_ type: duckdb_type) -> Bool {
        switch type {
        case DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_BLOB, DUCKDB_TYPE_BOOLEAN,
             DUCKDB_TYPE_TINYINT, DUCKDB_TYPE_SMALLINT, DUCKDB_TYPE_INTEGER, DUCKDB_TYPE_BIGINT,
             DUCKDB_TYPE_UTINYINT, DUCKDB_TYPE_USMALLINT, DUCKDB_TYPE_UINTEGER, DUCKDB_TYPE_UBIGINT,
             DUCKDB_TYPE_FLOAT, DUCKDB_TYPE_DOUBLE, DUCKDB_TYPE_HUGEINT, DUCKDB_TYPE_UHUGEINT,
             DUCKDB_TYPE_UUID, DUCKDB_TYPE_DATE, DUCKDB_TYPE_TIME,
             DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_S, DUCKDB_TYPE_TIMESTAMP_MS, DUCKDB_TYPE_TIMESTAMP_NS:
            return true
        default:
            return false
        }
    }

    static func requiresTextCast(_ type: duckdb_type) -> Bool {
        !isNativelyDecodable(type)
    }
}

enum HugeIntFormatter {
    static func format(upper: Int64, lower: UInt64) -> String {
        if upper == 0 {
            return String(lower)
        }
        let negative = upper < 0
        var magHigh: UInt64
        var magLow: UInt64
        if negative {
            let low = ~lower &+ 1
            let carry: UInt64 = low == 0 ? 1 : 0
            magHigh = ~UInt64(bitPattern: upper) &+ carry
            magLow = low
        } else {
            magHigh = UInt64(bitPattern: upper)
            magLow = lower
        }
        let digits = decimalString(high: magHigh, low: magLow)
        return negative ? "-\(digits)" : digits
    }

    static func formatUnsigned(upper: UInt64, lower: UInt64) -> String {
        if upper == 0 {
            return String(lower)
        }
        return decimalString(high: upper, low: lower)
    }

    private static func decimalString(high: UInt64, low: UInt64) -> String {
        var parts: [UInt32] = [
            UInt32(low & 0xFFFF_FFFF),
            UInt32((low >> 32) & 0xFFFF_FFFF),
            UInt32(high & 0xFFFF_FFFF),
            UInt32((high >> 32) & 0xFFFF_FFFF),
        ]
        var digits = ""
        repeat {
            var remainder: UInt64 = 0
            for index in stride(from: parts.count - 1, through: 0, by: -1) {
                let acc = (remainder << 32) | UInt64(parts[index])
                parts[index] = UInt32(acc / 10)
                remainder = acc % 10
            }
            digits = "\(remainder)\(digits)"
        } while parts.contains(where: { $0 != 0 })
        return digits.isEmpty ? "0" : digits
    }
}
