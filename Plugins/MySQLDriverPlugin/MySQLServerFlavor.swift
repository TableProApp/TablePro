//
//  MySQLServerFlavor.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated internal struct MySQLEngineVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(parsing text: Substring) {
        let parts = text.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        self.init(major: major, minor: parts.count > 1 ? parts[1] : 0, patch: parts.count > 2 ? parts[2] : 0)
    }

    static func < (lhs: MySQLEngineVersion, rhs: MySQLEngineVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

nonisolated internal enum MySQLServerFlavor: Equatable, Sendable {
    case mysql
    case mariadb
    case tidb(version: MySQLEngineVersion?)
    case databend
    case oceanbase(version: MySQLEngineVersion?)

    static let tidbVariant = "TiDB"
    static let databendVariant = "Databend"
    static let oceanbaseVariant = "OceanBase"

    static let oceanbaseUnlimitedQueryTimeoutMicroseconds = 3_216_672_000_000_000

    static func fromBanner(_ banner: String?) -> MySQLServerFlavor {
        guard let banner else { return .mysql }
        if let version = tidbVersion(fromBanner: banner) {
            return .tidb(version: version)
        }
        if isDatabendBanner(banner) {
            return .databend
        }
        return banner.lowercased().contains("mariadb") ? .mariadb : .mysql
    }

    static func tidbVersion(fromBanner banner: String) -> MySQLEngineVersion? {
        guard let marker = banner.range(of: "-TiDB-v", options: .caseInsensitive) else { return nil }
        return MySQLEngineVersion(parsing: banner[marker.upperBound...])
            ?? MySQLEngineVersion(major: 0, minor: 0, patch: 0)
    }

    static func tidbVersion(fromReleaseInfo info: String) -> MySQLEngineVersion? {
        guard let marker = info.range(of: "Release Version: v", options: .caseInsensitive) else { return nil }
        return MySQLEngineVersion(parsing: info[marker.upperBound...])
    }

    static func isDatabendBanner(_ banner: String) -> Bool {
        banner.range(of: #"^\d+\.\d+\.\d+-v\d+\.\d+\.\d+-"#, options: .regularExpression) != nil
    }

    static func oceanbaseVersion(fromVersionComment comment: String) -> MySQLEngineVersion? {
        guard let name = comment.range(
            of: #"^OceanBase(_CE)? +(?=\d)"#, options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return MySQLEngineVersion(parsing: comment[name.upperBound...])
    }

    static func oceanbaseVersion(fromServerVersion version: String) -> MySQLEngineVersion? {
        guard let marker = version.range(
            of: #"-OceanBase(_CE)?-v(?=\d)"#, options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return MySQLEngineVersion(parsing: version[marker.upperBound...])
    }

    var isMariaDB: Bool { self == .mariadb }

    var isTiDB: Bool {
        guard case .tidb = self else { return false }
        return true
    }

    var isDatabend: Bool { self == .databend }

    var isOceanBase: Bool {
        guard case .oceanbase = self else { return false }
        return true
    }

    var tidbVersion: MySQLEngineVersion? {
        guard case .tidb(let version) = self else { return nil }
        return version
    }

    var systemDatabaseNames: [String] {
        switch self {
        case .mysql, .mariadb:
            return ["information_schema", "mysql", "performance_schema", "sys"]
        case .tidb:
            return ["INFORMATION_SCHEMA", "METRICS_SCHEMA", "PERFORMANCE_SCHEMA", "mysql", "sys"]
        case .databend:
            return ["information_schema", "system"]
        case .oceanbase:
            return ["information_schema", "mysql", "oceanbase", "__recyclebin", "__public", "SYS", "LBACSYS", "ORAAUDITOR"]
        }
    }

    /// Whether the server's replies carry the session status flags `SERVER_STATUS_IN_TRANS` is read
    /// from, so a caller can be told what the session has open.
    ///
    /// Measured with the app's own libmariadb 3.4.4 against MySQL 5.5.62 and 8.4.11, MariaDB 5.5.64
    /// and 11.4.13 and TiDB v8.5.1: all five report the flag, including the transaction that
    /// `SET autocommit = 0` plus a write opens. Databend and OceanBase are unmeasured, so they
    /// report nothing rather than reporting "no transaction" from a flag that may never be set.
    var reportsSessionStatusFlags: Bool {
        switch self {
        case .mysql, .mariadb, .tidb:
            return true
        case .databend, .oceanbase:
            return false
        }
    }

    var listsSequencesAsTables: Bool { !isTiDB }

    var dropsIdleSessionOnKillQuery: Bool { isTiDB }

    var preparesOnServer: Bool { !isDatabend }

    func beginTransactionStatement(mode: PluginTransactionAccessMode) -> String {
        guard !isDatabend else { return "BEGIN" }
        guard mode == .readWrite else { return "START TRANSACTION" }
        return "START TRANSACTION \(readWriteAccessModeClause)"
    }

    private var readWriteAccessModeClause: String {
        switch self {
        case .mysql, .mariadb:
            return "/*!50605 READ WRITE */"
        case .tidb, .oceanbase, .databend:
            return "READ WRITE"
        }
    }

    func queryTimeoutStatements(seconds: Int) -> [String] {
        switch self {
        case .mariadb:
            return ["SET SESSION max_statement_time = \(seconds)"]
        case .databend:
            return ["SET max_execute_time_in_seconds = \(seconds)"]
        case .oceanbase:
            let microseconds = seconds > 0 ? seconds * 1_000_000 : Self.oceanbaseUnlimitedQueryTimeoutMicroseconds
            return ["SET SESSION ob_query_timeout = \(microseconds)", "SET SESSION max_execution_time = 0"]
        case .mysql, .tidb:
            return ["SET SESSION max_execution_time = \(seconds * 1_000)"]
        }
    }

    func selectLimitStatement(rows: UInt64) -> String {
        isDatabend ? "SET max_result_rows = \(rows)" : "SET SQL_SELECT_LIMIT = \(rows)"
    }

    var selectLimitResetStatement: String {
        isDatabend ? "SET max_result_rows = 0" : "SET SQL_SELECT_LIMIT = DEFAULT"
    }

    var selectLimitProbeStatement: String {
        isDatabend
            ? "SELECT value FROM system.settings WHERE name = 'max_result_rows'"
            : "SELECT @@sql_select_limit LIMIT 1"
    }

    func isInterruptedByKill(errno: UInt32, message: String) -> Bool {
        guard isDatabend else { return errno == 1_317 }
        return errno == 1_105 && message.contains("AbortedQuery")
    }
}

nonisolated internal enum MySQLFlavorResolution {
    static func needsTiDBVersionProbe(banner: String?, variant: String?) -> Bool {
        variant == MySQLServerFlavor.tidbVariant && !MySQLServerFlavor.fromBanner(banner).isTiDB
    }

    static func needsDatabendProbe(banner: String?, variant: String?) -> Bool {
        variant == MySQLServerFlavor.databendVariant && !MySQLServerFlavor.fromBanner(banner).isDatabend
    }

    static func oceanbaseFlavor(versionComment: String?, serverVersion: String?) -> MySQLServerFlavor? {
        let version = versionComment.flatMap(MySQLServerFlavor.oceanbaseVersion(fromVersionComment:))
            ?? serverVersion.flatMap(MySQLServerFlavor.oceanbaseVersion(fromServerVersion:))
        return version.map { .oceanbase(version: $0) }
    }

    static let tidbVersionProbe = "SELECT tidb_version()"
    static let databendProbe = "SELECT value FROM system.settings WHERE name = 'max_result_rows'"
    static let oceanbaseProbe = "SELECT @@version_comment, @@version"
    static let connectionIdentifierProbe = "SELECT CONNECTION_ID()"
}
