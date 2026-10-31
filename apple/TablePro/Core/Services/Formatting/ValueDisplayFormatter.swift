//
//  ValueDisplayFormatter.swift
//  TablePro
//

import Foundation
import TableProUtilities

/// Renders one raw cell value under one display format.
///
/// Nothing here reads a setting or a store, which is the point: this is what the data grid calls
/// per cell, and it has to stay reachable without dragging the preference layer behind it.
/// Resolving *which* format a column carries is a separate job with separate dependencies, and it
/// lives in `ValueDisplayFormatService`.
@MainActor
enum ValueDisplayFormatter {
    /// nil where the format cannot render this value, so the caller falls back to how the column
    /// would have read without it rather than showing a value the format did not actually produce.
    static func apply(
        _ rawValue: String,
        format: ValueDisplayFormat,
        columnType: ColumnType? = nil
    ) -> String? {
        switch format {
        case .raw:
            return rawValue
        case .text:
            return BinaryTextDecoder.decode(isoLatin1: rawValue, columnType: columnType)
        case .uuid:
            return formatAsUuid(rawValue, order: .stored)
        case .uuidSwappedTime:
            return formatAsUuid(rawValue, order: .swappedTime)
        case .unixTimestamp:
            return formatAsTimestamp(rawValue, divideBy: 1)
        case .unixTimestampMillis:
            return formatAsTimestamp(rawValue, divideBy: 1_000)
        case .json, .phpSerialized:
            return rawValue
        case .messagePack, .protobuf, .igbinary, .avro:
            guard let data = rawValue.data(using: .isoLatin1), let decoder = format.binaryValueFormat else { return nil }
            return BinaryValueDecoding.text(data, format: decoder)
        }
    }

    static func apply(
        _ rawValue: Data,
        format: ValueDisplayFormat,
        columnType: ColumnType? = nil
    ) -> String? {
        switch format {
        case .text:
            return BinaryTextDecoder.decode(rawValue, columnType: columnType)
        case .uuid, .uuidSwappedTime:
            guard rawValue.count == 16 else { return nil }
            let order: UUIDByteOrder = format == .uuidSwappedTime ? .swappedTime : .stored
            return insertUuidHyphens(order.uuidBytes(fromStored: [UInt8](rawValue)).hexEncoded)
        case .messagePack, .protobuf, .igbinary, .avro:
            guard let decoder = format.binaryValueFormat else { return nil }
            return BinaryValueDecoding.text(rawValue, format: decoder)
        case .raw, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized:
            return nil
        }
    }

    private static func formatAsUuid(_ rawValue: String, order: UUIDByteOrder) -> String {
        if let data = rawValue.data(using: .isoLatin1), data.count == 16 {
            return insertUuidHyphens(order.uuidBytes(fromStored: [UInt8](data)).hexEncoded)
        }

        var hex = rawValue
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        hex = hex.replacingOccurrences(of: "-", with: "")

        let digits = Array(hex.utf8)
        let stored = stride(from: 0, to: digits.count, by: 2).compactMap { index -> UInt8? in
            guard index + 1 < digits.count, let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else {
                return nil
            }
            return high << 4 | low
        }
        guard digits.count == 32, stored.count == 16 else { return rawValue }

        return insertUuidHyphens(order.uuidBytes(fromStored: stored).hexEncoded)
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func insertUuidHyphens(_ hex: String) -> String {
        let ns = hex as NSString
        let p1 = ns.substring(with: NSRange(location: 0, length: 8))
        let p2 = ns.substring(with: NSRange(location: 8, length: 4))
        let p3 = ns.substring(with: NSRange(location: 12, length: 4))
        let p4 = ns.substring(with: NSRange(location: 16, length: 4))
        let p5 = ns.substring(with: NSRange(location: 20, length: 12))
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }

    private static func formatAsTimestamp(_ rawValue: String, divideBy divisor: Double) -> String {
        guard let numericValue = Double(rawValue) else { return rawValue }
        let seconds = numericValue / divisor
        let date = Date(timeIntervalSince1970: seconds)
        return DateFormattingService.shared.format(date)
    }
}

// swappedTime is MySQL's UUID_TO_BIN(uuid, 1): stored `1026 BABA 6CCD780C 9564…` is `6ccd780c-baba-1026-9564-…`.
internal enum UUIDByteOrder: Sendable {
    case stored
    case swappedTime

    func uuidBytes(fromStored stored: [UInt8]) -> [UInt8] {
        guard self == .swappedTime, stored.count == 16 else { return stored }
        return Array(stored[4..<8] + stored[2..<4] + stored[0..<2] + stored[8..<16])
    }

    func storedBytes(fromUUID uuid: [UInt8]) -> [UInt8] {
        guard self == .swappedTime, uuid.count == 16 else { return uuid }
        return Array(uuid[6..<8] + uuid[4..<6] + uuid[0..<4] + uuid[8..<16])
    }
}
