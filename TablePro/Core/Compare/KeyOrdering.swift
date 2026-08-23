//
//  KeyOrdering.swift
//  TablePro
//
//  The order the merge join walks both streams in.
//
//  Rows arrive ordered by the server's own collation, so the client comparator
//  has to agree with it or the join desynchronises and reports rows that exist
//  on both sides as a delete plus an insert. Three rules keep that from
//  happening silently:
//
//  1. A numeric key column is compared as an exact decimal. Going through
//     Double collapses any two integers that share the first 53 bits, so a pair
//     of Snowflake ids one apart matched as the same row and the engine emitted
//     an UPDATE that overwrote a different row.
//  2. A text key whose collation is case-insensitive is compared case-folded.
//     The server treats 'Alice' and 'ALICE' as one key, so a byte comparator
//     reports an orphan insert for a row the target already has.
//  3. Every other key is compared by UTF-8 bytes.
//
//  None of the three is trusted on its own: the stream is verified as it is
//  read, for every order kind, so a server whose collation disagrees is
//  reported rather than guessed at. That check is the actual safety net, which
//  is why it is no longer conditional.
//
//  A NULL is never a usable row identity, so a row carrying one in a key column
//  is excluded from the comparison rather than given an arbitrary sort position.
//

import Foundation
import TableProPluginKit

internal struct KeyColumnDescriptor: Hashable, Sendable {
    internal let name: String
    internal let dataType: String?
    internal let collation: String?

    internal init(name: String, dataType: String? = nil, collation: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.collation = collation
    }
}

internal struct KeyOrdering {
    internal enum ColumnOrder: Equatable {
        case numeric
        case caseSensitiveText
        case caseInsensitiveText
    }

    private let orders: [ColumnOrder]

    internal init(orders: [ColumnOrder]) {
        self.orders = orders
    }

    internal func compare(_ lhs: [PluginCellValue], _ rhs: [PluginCellValue]) -> ComparisonResult {
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let order = index < orders.count ? orders[index] : .caseSensitiveText
            let result = Self.compare(pair.0, pair.1, using: order)
            guard result == .orderedSame else { return result }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    internal static func hasNullComponent(_ key: [PluginCellValue]) -> Bool {
        key.contains { if case .null = $0 { return true } else { return false } }
    }

    /// The row's identity, which is what excluding one row from a sync keys on, so two different
    /// composite keys must never render the same. Joining with ", " made ("a", "b, c") and
    /// ("a, b", "c") identical and silently excluded the wrong row. A unit separator cannot appear
    /// in a key value.
    internal static func identity(of key: [PluginCellValue]) -> String {
        key.map(component(of:)).joined(separator: "\u{1F}")
    }

    /// What a person reads. Ambiguity is fine here, because nothing keys on it.
    internal static func description(of key: [PluginCellValue]) -> String {
        key.map(component(of:)).joined(separator: ", ")
    }

    private static func component(of value: PluginCellValue) -> String {
        switch value {
        case .null: return "NULL"
        case .text(let text): return text
        case .bytes(let data): return data.base64EncodedString()
        }
    }

    internal static func orders(for keyColumns: [String], descriptors: [KeyColumnDescriptor]) -> [ColumnOrder] {
        keyColumns.map { column in
            let lowered = column.lowercased()
            guard let descriptor = descriptors.first(where: { $0.name.lowercased() == lowered }) else {
                return .caseSensitiveText
            }
            if isNumeric(descriptor.dataType) { return .numeric }
            return isCaseInsensitive(descriptor.collation) ? .caseInsensitiveText : .caseSensitiveText
        }
    }

    internal static func isNumeric(_ dataType: String?) -> Bool {
        guard let dataType else { return false }
        let base = dataType.lowercased().prefix { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if numericTypeNames.contains(base) { return true }
        guard let leading = base.split(separator: " ").first else { return false }
        return numericTypeNames.contains(String(leading))
    }

    /// Named per engine rather than guessed: MySQL and MariaDB suffix `_ci`, SQL Server spells
    /// `_CI_` in the middle of a collation name, and SQLite has exactly one, `NOCASE`. A name
    /// this does not recognise stays case-sensitive, where the stream-order check covers it.
    internal static func isCaseInsensitive(_ collation: String?) -> Bool {
        guard let collation, !collation.isEmpty else { return false }
        let lowered = collation.lowercased()
        if lowered == "nocase" { return true }
        if lowered.hasSuffix("_ci") { return true }
        return lowered.contains("_ci_")
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
            guard let left = decimalValue(lhs), let right = decimalValue(rhs) else {
                return compareBytes(byteValue(lhs), byteValue(rhs))
            }
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .caseSensitiveText:
            return compareBytes(byteValue(lhs), byteValue(rhs))
        case .caseInsensitiveText:
            return compareBytes(foldedByteValue(lhs), foldedByteValue(rhs))
        }
    }

    private static func compareBytes(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
    }

    /// `Decimal` carries 38 significant digits, which covers every integer key an engine can
    /// hold and the NUMERIC range in practice. A value that will not parse returns nil so the
    /// caller falls back to bytes, rather than collapsing onto a shared sentinel the way the
    /// old `?? 0` did.
    private static func decimalValue(_ value: PluginCellValue) -> Decimal? {
        switch value {
        case .null, .bytes:
            return nil
        case .text(let text):
            return Decimal(string: text.trimmingCharacters(in: .whitespaces), locale: Self.posixLocale)
        }
    }

    private static func byteValue(_ value: PluginCellValue) -> [UInt8] {
        switch value {
        case .null: return []
        case .text(let text): return Array(text.utf8)
        case .bytes(let data): return Array(data)
        }
    }

    private static func foldedByteValue(_ value: PluginCellValue) -> [UInt8] {
        switch value {
        case .null: return []
        case .text(let text): return Array(text.lowercased().utf8)
        case .bytes(let data): return Array(data)
        }
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
}
