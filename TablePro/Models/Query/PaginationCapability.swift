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
    /// The engine cannot skip rows, so a statement the app writes can only read the leading ones. A non-nil
    /// `maximumRows` is also the most one statement returns; nil means the engine caps nothing.
    case leadingRowsOnly(maximumRows: Int?)

    var allowsSeeking: Bool {
        if case .offset = self { return true }
        return false
    }

    var maximumRows: Int? {
        if case .leadingRowsOnly(let maximumRows) = self { return maximumRows }
        return nil
    }

    /// CQL has no `OFFSET`, but a driver that builds and runs its own browse walks its paging state to any row. So
    /// an engine that cannot skip rows and caps nothing pages through such a plugin, and reads only its leading
    /// rows through an older one that leaves the query to the app. A ceiling still holds whoever builds the query.
    func resolved(pluginBuildsBrowse: Bool) -> PaginationCapability {
        guard pluginBuildsBrowse, self == .leadingRowsOnly(maximumRows: nil) else { return self }
        return .offset
    }

    func clampedRowCount(_ requested: Int) -> Int {
        guard let maximumRows else { return requested }
        return min(requested, maximumRows)
    }

    static func of(_ databaseType: DatabaseType) -> PaginationCapability {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.capabilities.pagination ?? .offset
    }
}
