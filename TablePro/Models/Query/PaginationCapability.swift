//
//  PaginationCapability.swift
//  TablePro
//

import Foundation

/// How far into a result an engine lets the app read.
///
/// An engine fact, next to `SQLDialectDescriptor.paginationStyle` rather than inside it:
/// `PaginationStyle` is `@frozen`, so a case for "cannot skip rows" would be a breaking PluginKit
/// change and a re-release of every plugin, and the spelling of a clause is a different question from
/// whether the engine can seek at all.
internal enum PaginationCapability: Equatable, Sendable {
    /// The engine skips rows with OFFSET and returns as many as it is asked for.
    case offset
    /// The engine cannot skip rows and returns at most `maximumRows` from one statement, so the
    /// only rows it can show are the leading ones.
    case leadingRowsOnly(maximumRows: Int)

    var allowsSeeking: Bool {
        if case .offset = self { return true }
        return false
    }

    var maximumRows: Int? {
        if case .leadingRowsOnly(let maximumRows) = self { return maximumRows }
        return nil
    }

    func clampedRowCount(_ requested: Int) -> Int {
        guard let maximumRows else { return requested }
        return min(requested, maximumRows)
    }

    static func of(_ databaseType: DatabaseType) -> PaginationCapability {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.capabilities.pagination ?? .offset
    }
}
