//
//  SQLExportSnapshot.swift
//  SQLExportPlugin
//

import Foundation
import os
import TableProPluginKit

/// Holds one read-consistent view of the database for the length of an export.
///
/// Without it, a dump of several tables reads each one at a different moment, so a row inserted
/// between two reads appears in the child table and not in its parent. The statement that fixes it
/// is not portable: MySQL takes a modifier on `START TRANSACTION`, PostgreSQL sets the isolation
/// level on `BEGIN`, and SQLite gets the same guarantee from a plain deferred transaction. An
/// engine with no spelling for it opens nothing rather than sending a statement it would reject.
internal struct SQLExportSnapshot {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLExportSnapshot")

    private let dialect: SqlDialect

    internal init(dialect: SqlDialect) {
        self.dialect = dialect
    }

    internal var beginStatement: String? {
        switch dialect {
        case .mysql: return "START TRANSACTION WITH CONSISTENT SNAPSHOT"
        case .postgres: return "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"
        case .sqlite: return "BEGIN"
        default: return nil
        }
    }

    internal var endStatement: String? {
        beginStatement == nil ? nil : "COMMIT"
    }

    internal func begin(on dataSource: any PluginExportDataSource) async throws {
        guard let beginStatement else { return }
        _ = try await dataSource.execute(query: beginStatement)
    }

    /// A failed end is logged rather than thrown: the dump is already written, and turning a
    /// cleanup failure into an export failure would throw away a file that is correct.
    internal func end(on dataSource: any PluginExportDataSource) async {
        guard let endStatement else { return }
        do {
            _ = try await dataSource.execute(query: endStatement)
        } catch {
            Self.logger.warning("Failed to close the export snapshot: \(error.localizedDescription)")
        }
    }
}
