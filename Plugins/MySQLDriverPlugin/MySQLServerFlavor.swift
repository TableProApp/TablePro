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

    /// The MySQL handshake banner is OceanBase's `_display_mysql_version`, which is `5.7.25` on a
    /// direct connection and `5.6.25` through OBProxy: it never names the engine. `@@version_comment`
    /// is what does, as `OceanBase_CE 4.4.2.1 (r...)` or `OceanBase 3.1.3 (r...)`.
    static func namesOceanBase(_ versionComment: String) -> Bool {
        versionComment.range(of: "oceanbase", options: .caseInsensitive) != nil
    }

    static func oceanbaseVersion(fromVersionComment comment: String) -> MySQLEngineVersion? {
        guard let name = comment.range(of: "OceanBase", options: .caseInsensitive) else { return nil }
        let rest = comment[name.upperBound...].drop { $0.isLetter || $0 == "_" || $0 == "-" || $0.isWhitespace }
        return MySQLEngineVersion(parsing: rest)
    }

    var isMariaDB: Bool { self == .mariadb }

    var isTiDB: Bool {
        guard case .tidb = self else { return false }
        return true
    }

    var isDatabend: Bool { self == .databend }

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
            return ["information_schema", "mysql", "oceanbase"]
        }
    }

    var maintenanceOperations: [PluginMaintenanceOperation] {
        switch self {
        case .mysql, .mariadb:
            return MySQLMaintenance.operations
        case .tidb, .databend, .oceanbase:
            return [MySQLMaintenance.analyzeOperation]
        }
    }

    var listsSequencesAsTables: Bool { !isTiDB }

    var dropsIdleSessionOnKillQuery: Bool { isTiDB }

    var preparesOnServer: Bool { !isDatabend }

    func beginTransactionStatement(mode: PluginTransactionAccessMode) -> String {
        guard !isDatabend else { return "BEGIN" }
        return mode == .readWrite ? "START TRANSACTION READ WRITE" : "START TRANSACTION"
    }

    /// OceanBase enforces `ob_query_timeout` of its own, 10 seconds by default, and
    /// `max_execution_time` governs read-only statements alone: measured on 4.4.2.1, an `UPDATE`
    /// under a 30 second `max_execution_time` still failed at 10 seconds with error 4012. So the
    /// setting has to move OceanBase's own limit, in microseconds, whatever its value. Zero is the
    /// setting's "no limit", which an export relies on, and the server clamps what it accepts
    /// there; this is what it clamps to.
    static let oceanbaseUnlimitedQueryTimeoutMicroseconds = 3_216_672_000_000_000

    static func oceanbaseQueryTimeoutStatement(seconds: Int) -> String {
        let microseconds = seconds > 0
            ? seconds * 1_000_000
            : oceanbaseUnlimitedQueryTimeoutMicroseconds
        return "SET SESSION max_execution_time = \(max(seconds, 0) * 1_000), ob_query_timeout = \(microseconds)"
    }

    func queryTimeoutStatement(seconds: Int) -> String {
        switch self {
        case .mariadb:
            return "SET SESSION max_statement_time = \(seconds)"
        case .databend:
            return "SET max_execute_time_in_seconds = \(seconds)"
        case .oceanbase:
            return Self.oceanbaseQueryTimeoutStatement(seconds: seconds)
        case .mysql, .tidb:
            return "SET SESSION max_execution_time = \(seconds * 1_000)"
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

    static let tidbVersionProbe = "SELECT tidb_version()"
    static let databendProbe = "SELECT value FROM system.settings WHERE name = 'max_result_rows'"
    static let oceanbaseProbe = "SELECT @@version_comment"
    static let connectionIdentifierProbe = "SELECT CONNECTION_ID()"
}
