//
//  SQLExportInsertMode.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

/// How a dump's `INSERT` behaves when a row it writes already exists.
public enum SQLExportInsertMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case insert
    case ignoreExisting
    case replaceExisting
    case updateExisting

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .insert: return String(localized: "Insert")
        case .ignoreExisting: return String(localized: "Insert, skip existing")
        case .replaceExisting: return String(localized: "Replace existing")
        case .updateExisting: return String(localized: "Update existing")
        }
    }
}

/// Renders the two dialect-specific halves of an `INSERT`: what comes before the column list and
/// what comes after the last row of values.
///
/// Every engine spells conflict handling differently, and three of the four spellings are not
/// interchangeable: MySQL puts it in the verb (`INSERT IGNORE`, `REPLACE INTO`), SQLite puts it in
/// a resolution clause (`INSERT OR IGNORE`), and PostgreSQL puts it in a trailing `ON CONFLICT`
/// that has to name the conflict target. An engine with no spelling at all falls back to a plain
/// `INSERT` and says so, rather than writing a statement the restore would reject.
public struct SQLExportInsertRenderer {
    public struct Rendered: Equatable, Sendable {
        public let prefix: String
        public let suffix: String
        public let warning: String?
    }

    private let dialect: SqlDialect
    private let quoteIdentifier: (String) -> String

    public init(dialect: SqlDialect, quoteIdentifier: @escaping (String) -> String) {
        self.dialect = dialect
        self.quoteIdentifier = quoteIdentifier
    }

    public func render(
        mode: SQLExportInsertMode,
        tableRef: String,
        quotedColumns: String,
        overriding: String,
        columnNames: [String],
        primaryKeyColumns: [String]
    ) -> Rendered {
        let plain = Rendered(
            prefix: "INSERT INTO \(tableRef) (\(quotedColumns))\(overriding) VALUES\n",
            suffix: "",
            warning: nil
        )
        switch mode {
        case .insert:
            return plain
        case .ignoreExisting:
            return renderIgnore(plain: plain, tableRef: tableRef, quotedColumns: quotedColumns, overriding: overriding)
        case .replaceExisting:
            return renderReplace(
                plain: plain, tableRef: tableRef, quotedColumns: quotedColumns, overriding: overriding,
                columnNames: columnNames, primaryKeyColumns: primaryKeyColumns)
        case .updateExisting:
            return renderUpdate(
                plain: plain, tableRef: tableRef, quotedColumns: quotedColumns, overriding: overriding,
                columnNames: columnNames, primaryKeyColumns: primaryKeyColumns)
        }
    }

    private func renderIgnore(
        plain: Rendered,
        tableRef: String,
        quotedColumns: String,
        overriding: String
    ) -> Rendered {
        switch dialect {
        case .mysql:
            return Rendered(
                prefix: "INSERT IGNORE INTO \(tableRef) (\(quotedColumns))\(overriding) VALUES\n",
                suffix: "", warning: nil)
        case .sqlite:
            return Rendered(
                prefix: "INSERT OR IGNORE INTO \(tableRef) (\(quotedColumns))\(overriding) VALUES\n",
                suffix: "", warning: nil)
        case .postgres:
            return Rendered(prefix: plain.prefix, suffix: "\nON CONFLICT DO NOTHING", warning: nil)
        default:
            return Rendered(prefix: plain.prefix, suffix: "", warning: Self.unsupportedWarning)
        }
    }

    /// PostgreSQL has no `REPLACE`, and its nearest equivalent is an upsert that overwrites every
    /// non-key column, so replace and update render the same there.
    private func renderReplace(
        plain: Rendered,
        tableRef: String,
        quotedColumns: String,
        overriding: String,
        columnNames: [String],
        primaryKeyColumns: [String]
    ) -> Rendered {
        switch dialect {
        case .mysql:
            return Rendered(
                prefix: "REPLACE INTO \(tableRef) (\(quotedColumns))\(overriding) VALUES\n",
                suffix: "", warning: nil)
        case .sqlite:
            return Rendered(
                prefix: "INSERT OR REPLACE INTO \(tableRef) (\(quotedColumns))\(overriding) VALUES\n",
                suffix: "", warning: nil)
        case .postgres:
            return renderUpdate(
                plain: plain, tableRef: tableRef, quotedColumns: quotedColumns, overriding: overriding,
                columnNames: columnNames, primaryKeyColumns: primaryKeyColumns)
        default:
            return Rendered(prefix: plain.prefix, suffix: "", warning: Self.unsupportedWarning)
        }
    }

    private func renderUpdate(
        plain: Rendered,
        tableRef: String,
        quotedColumns: String,
        overriding: String,
        columnNames: [String],
        primaryKeyColumns: [String]
    ) -> Rendered {
        let updatable = columnNames.filter { !primaryKeyColumns.contains($0) }
        switch dialect {
        case .mysql:
            guard !updatable.isEmpty else {
                return Rendered(prefix: plain.prefix, suffix: "", warning: Self.noUpdatableColumnsWarning)
            }
            let assignments = updatable
                .map { "\(quoteIdentifier($0)) = VALUES(\(quoteIdentifier($0)))" }
                .joined(separator: ", ")
            return Rendered(
                prefix: plain.prefix,
                suffix: "\nON DUPLICATE KEY UPDATE \(assignments)",
                warning: nil)
        case .postgres, .sqlite:
            guard !primaryKeyColumns.isEmpty else {
                return Rendered(prefix: plain.prefix, suffix: "", warning: Self.noPrimaryKeyWarning)
            }
            guard !updatable.isEmpty else {
                return Rendered(prefix: plain.prefix, suffix: "\nON CONFLICT DO NOTHING", warning: nil)
            }
            let target = primaryKeyColumns.map(quoteIdentifier).joined(separator: ", ")
            let excluded = dialect == .postgres ? "EXCLUDED" : "excluded"
            let assignments = updatable
                .map { "\(quoteIdentifier($0)) = \(excluded).\(quoteIdentifier($0))" }
                .joined(separator: ", ")
            return Rendered(
                prefix: plain.prefix,
                suffix: "\nON CONFLICT (\(target)) DO UPDATE SET \(assignments)",
                warning: nil)
        default:
            return Rendered(prefix: plain.prefix, suffix: "", warning: Self.unsupportedWarning)
        }
    }

    private static var unsupportedWarning: String {
        String(localized: "This engine has no conflict handling for INSERT, so the rows are written as plain inserts.")
    }

    private static var noPrimaryKeyWarning: String {
        String(localized: "A table with no primary key has no conflict target, so its rows are written as plain inserts.")
    }

    private static var noUpdatableColumnsWarning: String {
        String(localized: "A table whose columns are all part of its key has nothing to update, so its rows are written as plain inserts.")
    }
}
