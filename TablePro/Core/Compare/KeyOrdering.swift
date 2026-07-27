//
//  KeyOrdering.swift
//  TablePro
//
//  The order the merge join walks both streams in.
//
//  Rows arrive ordered by the server's own collation, so the client comparator
//  has to agree with it or the join desynchronises and reports rows that exist
//  on both sides as a delete plus an insert. Two rules keep that from happening
//  silently:
//
//  1. A numeric key column is compared numerically, which matches every engine's
//     numeric ordering exactly. This covers the ordinary integer primary key.
//  2. Anything else is compared by UTF-8 bytes, and the stream is checked as it
//     is read. A server whose collation disagrees is reported, not guessed at.
//
//  A NULL is never a usable row identity, so a row carrying one in a key column
//  is excluded from the comparison rather than given an arbitrary sort position.
//

import Foundation
import TableProPluginKit

internal struct KeyOrdering {
    internal enum ColumnOrder: Equatable {
        case numeric
        case binaryText
    }

    private let orders: [ColumnOrder]

    internal init(orders: [ColumnOrder]) {
        self.orders = orders
    }

    internal var requiresStreamOrderCheck: Bool {
        orders.contains(.binaryText)
    }

    internal func compare(_ lhs: [PluginCellValue], _ rhs: [PluginCellValue]) -> ComparisonResult {
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let order = index < orders.count ? orders[index] : .binaryText
            let result = Self.compare(pair.0, pair.1, using: order)
            guard result == .orderedSame else { return result }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    internal static func hasNullComponent(_ key: [PluginCellValue]) -> Bool {
        key.contains { if case .null = $0 { return true } else { return false } }
    }

    internal static func description(of key: [PluginCellValue]) -> String {
        key.map { value in
            switch value {
            case .null: return "NULL"
            case .text(let text): return text
            case .bytes(let data): return data.base64EncodedString()
            }
        }
        .joined(separator: ", ")
    }

    internal static func orders(
        for keyColumns: [String],
        columnTypes: [String: String]
    ) -> [ColumnOrder] {
        keyColumns.map { column in
            let lowered = column.lowercased()
            let declared = columnTypes.first { $0.key.lowercased() == lowered }?.value
            return isNumeric(declared) ? .numeric : .binaryText
        }
    }

    internal static func isNumeric(_ dataType: String?) -> Bool {
        guard let dataType else { return false }
        let base = dataType.lowercased().prefix { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if numericTypeNames.contains(base) { return true }
        guard let leading = base.split(separator: " ").first else { return false }
        return numericTypeNames.contains(String(leading))
    }

    private static let numericTypeNames: Set<String> = [
        "int", "integer", "tinyint", "smallint", "mediumint", "bigint",
        "serial", "bigserial", "smallserial", "int2", "int4", "int8",
        "decimal", "numeric", "number", "float", "double", "double precision",
        "real", "money", "float4", "float8"
    ]

    private static func compare(
        _ lhs: PluginCellValue,
        _ rhs: PluginCellValue,
        using order: ColumnOrder
    ) -> ComparisonResult {
        switch order {
        case .numeric:
            let left = numericValue(lhs)
            let right = numericValue(rhs)
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .binaryText:
            let left = byteValue(lhs)
            let right = byteValue(rhs)
            if left == right { return .orderedSame }
            return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
        }
    }

    private static func numericValue(_ value: PluginCellValue) -> Double {
        switch value {
        case .null: return -.infinity
        case .text(let text): return Double(text.trimmingCharacters(in: .whitespaces)) ?? 0
        case .bytes: return 0
        }
    }

    private static func byteValue(_ value: PluginCellValue) -> [UInt8] {
        switch value {
        case .null: return []
        case .text(let text): return Array(text.utf8)
        case .bytes(let data): return Array(data)
        }
    }
}
