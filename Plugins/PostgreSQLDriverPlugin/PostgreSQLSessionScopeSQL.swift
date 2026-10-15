//
//  PostgreSQLSessionScopeSQL.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal struct PostgreSQLBoundStatement: Equatable, Sendable {
    let sql: String
    let parameters: [PluginCellValue]
}

internal enum PostgreSQLSessionScopeError: Error, Equatable {
    case abortedTransaction
    case sessionNotIdle
    case restoreRefused([String])
}

internal enum PostgreSQLSessionScopeSQL {
    /// Every `SET` a pg_dump 17.11 plain file runs and never puts back, the settings a value's text form depends on,
    /// and `session_replication_role`, which the import's foreign key switch sets.
    static let preservedNames = [
        "statement_timeout",
        "lock_timeout",
        "idle_in_transaction_session_timeout",
        "transaction_timeout",
        "client_encoding",
        "standard_conforming_strings",
        "search_path",
        "check_function_bodies",
        "xmloption",
        "client_min_messages",
        "row_security",
        "default_tablespace",
        "default_table_access_method",
        "DateStyle",
        "IntervalStyle",
        "extra_float_digits",
        "TimeZone",
        "session_replication_role"
    ]

    /// What pg_dump's own reading session sets. `ISO` alone changes DateStyle's output part and keeps the session's
    /// field order, as pg_dump's `SET DATESTYLE = ISO` does.
    static let verbatimReadSettings = [
        PluginSessionSetting(name: "DateStyle", value: "ISO"),
        PluginSessionSetting(name: "IntervalStyle", value: "postgres"),
        PluginSessionSetting(name: "extra_float_digits", value: "3")
    ]

    static var verbatimReadNames: [String] {
        verbatimReadSettings.map(\.name)
    }

    /// `pg_settings` spells `DateStyle`, `IntervalStyle` and `TimeZone` in mixed case, so the match ignores case.
    static func captureStatement(names: [String]) -> PostgreSQLBoundStatement {
        let filter = PostgreSQLObjectQueries.membership("pg_catalog.lower(name)", in: names.map { $0.lowercased() })
        return PostgreSQLBoundStatement(
            sql: "SELECT name, setting FROM pg_catalog.pg_settings WHERE \(filter)",
            parameters: []
        )
    }

    static func settings(fromRows rows: [[String?]], names: [String]) -> [PluginSessionSetting] {
        var reported: [String: String?] = [:]
        for row in rows {
            guard let first = row.first, let name = first else { continue }
            let value: String? = row.count > 1 ? row[1] : nil
            reported.updateValue(value, forKey: name.lowercased())
        }
        return names.compactMap { name in
            guard let value = reported[name.lowercased()] else { return nil }
            return PluginSessionSetting(name: name, value: value)
        }
    }

    /// Nil unless the server reported every one of `names`: a purpose applies all its settings or none.
    static func completeSettings(_ settings: [PluginSessionSetting], names: [String]) -> [PluginSessionSetting]? {
        let reported = Set(settings.map { $0.name.lowercased() })
        return names.allSatisfy { reported.contains($0.lowercased()) } ? settings : nil
    }

    /// One statement, so the server applies every setting or none: a refused one rolls back the statement's
    /// implicit transaction, or the savepoint the connection holds around it inside a block. A nil value binds SQL
    /// `NULL`, which `set_config` takes as a reset.
    static func setStatement(_ settings: [PluginSessionSetting]) -> PostgreSQLBoundStatement? {
        guard !settings.isEmpty else { return nil }
        var calls: [String] = []
        var parameters: [PluginCellValue] = []
        for (index, setting) in settings.enumerated() {
            calls.append("pg_catalog.set_config($\(index * 2 + 1), $\(index * 2 + 2), false)")
            parameters.append(.text(setting.name))
            parameters.append(setting.value.map { PluginCellValue.text($0) } ?? .null)
        }
        return PostgreSQLBoundStatement(sql: "SELECT \(calls.joined(separator: ", "))", parameters: parameters)
    }

    /// What each setting holds after `setStatement`, from the row it returned: `ISO` reads back as `ISO, MDY`.
    static func appliedSettings(_ requested: [PluginSessionSetting], reportedRow: [String?]) -> [PluginSessionSetting] {
        requested.enumerated().map { index, setting in
            let reported = index < reportedRow.count ? reportedRow[index] : nil
            return PluginSessionSetting(name: setting.name, value: reported ?? setting.value)
        }
    }

    /// The saved settings the session no longer holds. Setting `session_replication_role` takes a privilege even
    /// when the value does not change, so an unchanged setting is never written.
    static func changedSettings(
        saved: [PluginSessionSetting],
        current: [PluginSessionSetting]
    ) -> [PluginSessionSetting] {
        var currentValues: [String: String?] = [:]
        for setting in current {
            currentValues.updateValue(setting.value, forKey: setting.name.lowercased())
        }
        return saved.filter { setting in
            guard let value = currentValues[setting.name.lowercased()] else { return false }
            return value != setting.value
        }
    }

    /// In an aborted transaction the server refuses every statement but a rollback, and that rollback reverts only
    /// what the transaction itself set.
    static func canRestore(in state: PluginSessionTransactionState) -> Bool {
        state != .abortedTransaction
    }

    /// Inside a transaction the capture can read a `SET LOCAL` value, and the session-level restore of it would then
    /// outlive the commit in place of the session's own value, so a read scope opens on an idle session only.
    static func canOpenReadScope(in state: PluginSessionTransactionState) -> Bool {
        state == .idle
    }
}
