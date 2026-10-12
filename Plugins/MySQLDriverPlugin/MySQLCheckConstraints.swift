//
//  MySQLCheckConstraints.swift
//  MySQLDriverPlugin
//
//  Where a server's check constraints are read from, and whether it has any to read.
//

import Foundation
import TableProPluginKit

internal enum MySQLCheckConstraintSource: Equatable, Sendable {
    case unavailable
    case informationSchema
    case createTableStatement
    case databendCatalog
}

/// One decision for both the read and the edit, because "enforces CHECK" and "has a
/// `CHECK_CONSTRAINTS` table" are two different facts and treating them as one produced two bugs.
///
/// MySQL before 8.0.16 and MariaDB before 10.2.1 parse `ADD CONSTRAINT ... CHECK` and throw the
/// clause away: measured on 5.5.62, 5.6.51, 5.7.44, MariaDB 10.0.38 and 10.1.48, the statement
/// answers `Query OK` with no warning and the violating insert then succeeds. MariaDB 10.2.1 to
/// 10.2.21 and 10.3.0 to 10.3.9 enforce the constraint but have no catalog for it, so reading one
/// fails with `ERROR 1109 Unknown table 'CHECK_CONSTRAINTS'` and takes the whole Structure tab with
/// it; `SHOW CREATE TABLE` is what answers there.
internal enum MySQLCheckConstraints {
    static func source(banner: String?, flavor: MySQLServerFlavor) -> MySQLCheckConstraintSource {
        switch flavor {
        case .mysql:
            return MySQLServerVersion.isAtLeast((8, 0, 16), banner: banner) ? .informationSchema : .unavailable
        case .mariadb:
            guard MySQLServerVersion.isAtLeast((10, 2, 1), banner: banner) else { return .unavailable }
            return mariadbListsCheckConstraints(banner: banner) ? .informationSchema : .createTableStatement
        case .tidb(let version):
            guard let version, version >= MySQLEngineVersion(major: 7, minor: 2, patch: 0) else { return .unavailable }
            return .createTableStatement
        case .oceanbase(let version):
            guard let version, version >= MySQLEngineVersion(major: 4, minor: 0, patch: 0) else { return .unavailable }
            return .informationSchema
        case .databend:
            return .databendCatalog
        }
    }

    /// Whether a check constraint written to this server would survive. False while the version is
    /// unknown, so the statement is withheld rather than sent to a server that may discard it.
    static func supportsEditing(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        knowsVersion(banner: banner, flavor: flavor) && source(banner: banner, flavor: flavor) != .unavailable
    }

    /// Why this connected server has no check constraints to list or edit, or nil when it has.
    ///
    /// A server whose version is unknown refuses nothing. Every disconnect clears the banner and
    /// resets the flavor to `.mysql`, and the app keeps that handle installed across a reconnect,
    /// so reading "no version" as "too old" hides the Constraints tab on MariaDB 11 and words the
    /// reason as MySQL 8.0.16.
    static func refusal(banner: String?, flavor: MySQLServerFlavor) -> String? {
        guard knowsVersion(banner: banner, flavor: flavor),
              source(banner: banner, flavor: flavor) == .unavailable,
              let floor = versionFloorName(for: flavor)
        else { return nil }
        return String(format: String(localized: "Check constraints need %@ or later."), floor)
    }

    /// MySQL 8.0.16 to 8.0.18 takes `DROP CHECK` and answers `ERROR 1064` to `DROP CONSTRAINT`;
    /// 8.0.19 takes both. MariaDB never takes `DROP CHECK`.
    static func dropStatement(
        quotedTable: String,
        quotedName: String,
        banner: String?,
        flavor: MySQLServerFlavor
    ) -> String {
        let keyword = usesDropCheckKeyword(banner: banner, flavor: flavor) ? "DROP CHECK" : "DROP CONSTRAINT"
        return "ALTER TABLE \(quotedTable) \(keyword) \(quotedName)"
    }

    static func parse(createTable sql: String) -> [PluginCheckConstraintInfo] {
        guard let body = MySQLCreateTableScanner.firstGroup(in: Substring(sql)) else { return [] }
        return MySQLCreateTableScanner.topLevelElements(of: body).compactMap(checkConstraint(in:))
    }

    /// The catalog arrived mid-series: measured, 10.2.21 answers `ERROR 1109` and 10.2.22 lists the
    /// constraint, and the 10.3 series repeats that at 10.3.9 and 10.3.10.
    private static func mariadbListsCheckConstraints(banner: String?) -> Bool {
        guard let banner, let version = MySQLServerVersion.components(from: banner) else { return false }
        guard version.major == 10, version.minor <= 3 else {
            return MySQLServerVersion.isAtLeast((10, 4, 0), banner: banner)
        }
        return version.minor == 2 ? version.patch >= 22 : version.patch >= 10
    }

    private static func knowsVersion(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        switch flavor {
        case .mysql, .mariadb:
            guard let banner else { return false }
            return MySQLServerVersion.components(from: banner) != nil
        case .tidb(let version), .oceanbase(let version):
            return version != nil
        case .databend:
            return true
        }
    }

    private static func versionFloorName(for flavor: MySQLServerFlavor) -> String? {
        switch flavor {
        case .mysql: return "MySQL 8.0.16"
        case .mariadb: return "MariaDB 10.2.1"
        case .tidb: return "TiDB 7.2"
        case .oceanbase: return "OceanBase 4.0"
        case .databend: return nil
        }
    }

    private static func usesDropCheckKeyword(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        guard flavor == .mysql else { return false }
        return !MySQLServerVersion.isAtLeast((8, 0, 19), banner: banner)
    }

    private static func checkConstraint(in element: Substring) -> PluginCheckConstraintInfo? {
        var rest = element
        guard MySQLCreateTableScanner.consume("CONSTRAINT", from: &rest),
              let name = MySQLCreateTableScanner.consumeBacktickName(from: &rest),
              MySQLCreateTableScanner.consume("CHECK", from: &rest)
        else { return nil }
        rest = rest.drop(while: \.isWhitespace)
        guard rest.first == "(", let expression = MySQLCreateTableScanner.firstGroup(in: rest) else { return nil }
        return PluginCheckConstraintInfo(name: name, expression: expression.trimmingCharacters(in: .whitespaces))
    }
}
