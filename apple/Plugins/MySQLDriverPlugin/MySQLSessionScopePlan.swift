//
//  MySQLSessionScopePlan.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

/// Which session settings each purpose saves and sets on MySQL, and what putting them back takes.
internal enum MySQLSessionScopePlan {
    /// What a mysqldump or mariadb-dump file sets and puts back only at its end, which an imported file leaves changed
    /// when it stops early. `SHOW` reports only the ones the server has: `note_verbosity` is MariaDB's.
    ///
    /// `autocommit` is last, and closing restores in this order: `SET autocommit = 1` commits whatever the session
    /// still holds open, so every other setting is back before it.
    static let preservedNames = [
        "sql_mode",
        "time_zone",
        "character_set_client",
        "character_set_results",
        "collation_connection",
        "foreign_key_checks",
        "unique_checks",
        "sql_notes",
        "note_verbosity",
        "autocommit",
    ]

    static let verbatimNames = ["sql_mode", "time_zone"]

    static func savedNames(for purpose: PluginSessionPurpose) -> [String] {
        switch purpose {
        case .preserve:
            return preservedNames
        case .verbatimRead, .verbatimWrite:
            return verbatimNames
        case .relaxedForeignKeys:
            return ["foreign_key_checks"]
        @unknown default:
            return []
        }
    }

    /// What `purpose` sets, in order, given what was saved, or nil for a purpose this driver does not know. Reading
    /// runs as mysqldump's own connection does (`SET @@SQL_MODE = ''` and `TIME_ZONE = '+00:00'`), so no
    /// `ANSI_QUOTES` reaches the DDL and every TIMESTAMP comes out in UTC.
    static func applied(for purpose: PluginSessionPurpose, saved: [PluginSessionSetting]) -> [PluginSessionSetting]? {
        switch purpose {
        case .preserve:
            return []
        case .verbatimRead:
            return [
                PluginSessionSetting(name: "sql_mode", value: ""),
                PluginSessionSetting(name: "time_zone", value: "+00:00"),
            ]
        case .verbatimWrite:
            return [
                PluginSessionSetting(name: "sql_mode", value: writeMode(saved: saved)),
                PluginSessionSetting(name: "time_zone", value: "+00:00"),
            ]
        case .relaxedForeignKeys:
            return [PluginSessionSetting(name: "foreign_key_checks", value: "OFF")]
        @unknown default:
            return nil
        }
    }

    /// Writing accepts what the user's session accepts, plus zero dates and an AUTO_INCREMENT value of 0: the saved
    /// mode loses `NO_ZERO_DATE` and `NO_ZERO_IN_DATE` and gains `NO_AUTO_VALUE_ON_ZERO`, and every other flag stays.
    /// Strict flags stay because a copy can write into an existing table its rows do not fit, `NO_BACKSLASH_ESCAPES`
    /// because Object Copy spells its table DDL's literals for the session's mode, and the rest, `ALLOW_INVALID_DATES`
    /// among them, so nothing that copied before is refused now (`scripts/probes/check-mysql-dump-session.sh`, step e).
    ///
    /// `TRADITIONAL` goes too: `SHOW` reports it beside the flags it stands for, and setting it again brings both
    /// zero-date flags back. On MariaDB 13.0.2 and MySQL 8.4.11 it is the only combination mode `SHOW` reports that
    /// implies either one, and its other flags are reported alongside it, so they stay.
    static func writeMode(saved: [PluginSessionSetting]) -> String {
        let savedMode = saved.first { $0.name == "sql_mode" }?.value ?? ""
        var flags = savedMode
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !zeroDateModes.contains($0.uppercased()) }
        if !flags.contains(where: { $0.uppercased() == "NO_AUTO_VALUE_ON_ZERO" }) {
            flags.append("NO_AUTO_VALUE_ON_ZERO")
        }
        return flags.joined(separator: ",")
    }

    private static let zeroDateModes: Set<String> = ["NO_ZERO_DATE", "NO_ZERO_IN_DATE", "TRADITIONAL"]

    /// The settings a `SHOW SESSION VARIABLES` reply reports, in the order `names` asks for them. A name the server
    /// did not report is left out.
    static func captured(rows: [[PluginCellValue]], names: [String]) -> [PluginSessionSetting] {
        var reported: [String: String?] = [:]
        for row in rows {
            guard let name = row[safe: 0]?.asText?.lowercased() else { continue }
            reported.updateValue(row[safe: 1]?.asText, forKey: name)
        }
        return names.compactMap { name -> PluginSessionSetting? in
            guard let value = reported[name] else { return nil }
            return PluginSessionSetting(name: name, value: MySQLSessionStatements.reportedValue(name: name, value: value))
        }
    }

    /// One `SET SESSION` for each saved setting the session no longer holds, in the order they were saved, and whether
    /// every one of them is among them.
    ///
    /// `SET autocommit = 1` commits whatever transaction is open, and it may be the user's own, begun in the editor
    /// before the import ran, so while one is open `autocommit` stays as the file left it.
    static func restore(
        saved: [PluginSessionSetting],
        current: [PluginSessionSetting],
        isTransactionOpen: Bool
    ) -> (statements: [String], isComplete: Bool) {
        var statements: [String] = []
        var isComplete = true
        for setting in saved {
            if let now = current.first(where: { $0.name == setting.name }), now.value == setting.value { continue }
            if isTransactionOpen, setting.name == "autocommit" {
                isComplete = false
                continue
            }
            guard let statement = MySQLSessionStatements.assignment(name: setting.name, value: setting.value) else {
                continue
            }
            statements.append(statement)
        }
        return (statements, isComplete)
    }
}
