//
//  PluginTableKindDecoder.swift
//  TablePro
//

import Foundation

/// The whole vocabulary a driver may use for what an object is, read in one place.
///
/// System versioning travels inside the type string rather than beside it because `PluginTableInfo`
/// cannot gain a field: adding one would add a fourth public initializer to a shipped transfer
/// struct, which is the ABI break `CLAUDE.md` records from 0.49.0. The type string is the only
/// channel a driver already has, and this is the only reader of it.
///
/// The vocabulary is three exact spellings rather than a substring scan, so a driver that one day
/// says `SYSTEM VERSIONED SOMETHING ELSE` decodes to nil and is logged, instead of silently losing
/// Truncate.
nonisolated internal enum PluginTableKindDecoder {
    internal struct Decoded: Equatable, Sendable {
        /// Nil for a spelling this app does not know, which the adapter logs before falling back.
        internal let kind: TableInfo.TableType?
        internal let isSystemVersioned: Bool
    }

    internal static func decode(_ declaredType: String) -> Decoded {
        switch normalized(declaredType) {
        case "table", "base table", "prefix":
            return Decoded(kind: .table, isSystemVersioned: false)
        case "partitioned table":
            return Decoded(kind: .partitionedTable, isSystemVersioned: false)
        case "view":
            return Decoded(kind: .view, isSystemVersioned: false)
        case "materialized view":
            return Decoded(kind: .materializedView, isSystemVersioned: false)
        case "foreign table":
            return Decoded(kind: .foreignTable, isSystemVersioned: false)
        case "system table", "system base table", "system view":
            return Decoded(kind: .systemTable, isSystemVersioned: false)
        case "external table":
            return Decoded(kind: .externalTable, isSystemVersioned: false)
        case "sequence":
            return Decoded(kind: .sequence, isSystemVersioned: false)
        case "system versioned", "system versioned table":
            return Decoded(kind: .table, isSystemVersioned: true)
        case "system versioned partitioned table":
            return Decoded(kind: .partitionedTable, isSystemVersioned: true)
        default:
            return Decoded(kind: nil, isSystemVersioned: false)
        }
    }

    /// Underscores become spaces and runs of whitespace collapse, so `SYSTEM_VERSIONED` and
    /// `system  versioned` reach the same arm as `SYSTEM VERSIONED`.
    private static func normalized(_ declaredType: String) -> String {
        declaredType
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
