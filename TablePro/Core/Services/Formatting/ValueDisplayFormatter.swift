//
//  ValueDisplayFormatter.swift
//  TablePro
//

import Foundation

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
            return formatAsUuid(rawValue)
        case .unixTimestamp:
            return formatAsTimestamp(rawValue, divideBy: 1)
        case .unixTimestampMillis:
            return formatAsTimestamp(rawValue, divideBy: 1_000)
        case .json, .phpSerialized:
            return rawValue
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
        case .uuid:
            guard rawValue.count == 16 else { return nil }
            return formatAsUuid(rawValue.hexEncoded)
        case .raw, .unixTimestamp, .unixTimestampMillis, .json, .phpSerialized:
            return nil
        }
    }

    private static func formatAsUuid(_ rawValue: String) -> String {
        if let data = rawValue.data(using: .isoLatin1), data.count == 16 {
            let bytes = [UInt8](data)
            let hex = bytes.hexEncoded
            return insertUuidHyphens(hex)
        }

        var hex = rawValue
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        hex = hex.replacingOccurrences(of: "-", with: "")

        guard (hex as NSString).length == 32, hex.allSatisfy({ $0.isHexDigit }) else {
            return rawValue
        }

        return insertUuidHyphens(hex.lowercased())
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
