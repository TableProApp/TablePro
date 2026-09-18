//
//  MySQLServerVersion.swift
//  MySQLDriverPlugin
//
//  Feature floors for the catalogs the structure editor reads.
//  Compiled into the test target via project.yml.
//

import Foundation

/// One plugin serves MySQL and MariaDB, and they gained these catalogs at different releases.
/// Reading one that does not exist is not a soft failure: the structure load surfaces the error
/// and the whole Structure tab refuses to open, so each read is gated before it runs.
enum MySQLServerVersion {
    /// `(major, minor, patch)` from a version banner such as `8.0.36` or `10.6.16-MariaDB`.
    static func components(from banner: String) -> (major: Int, minor: Int, patch: Int)? {
        let leading = banner.prefix { $0.isNumber || $0 == "." }
        let parts = leading.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        return (major, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    static func isAtLeast(_ target: (Int, Int, Int), banner: String?) -> Bool {
        guard let banner, let version = components(from: banner) else { return false }
        if version.major != target.0 { return version.major > target.0 }
        if version.minor != target.1 { return version.minor > target.1 }
        return version.patch >= target.2
    }

    /// True only when the banner parses and names a version below `target`. An unreadable banner is
    /// not an old server, so a gate that picks legacy syntax asks this rather than `!isAtLeast`.
    static func isKnownBelow(_ target: (Int, Int, Int), banner: String?) -> Bool {
        guard let banner, components(from: banner) != nil else { return false }
        return !isAtLeast(target, banner: banner)
    }

    /// Whether the server has a statement timeout at all. MySQL gained `max_execution_time` in
    /// 5.7.8 and MariaDB `max_statement_time` in 10.1.1; measured, everything below answers
    /// `ERROR 1193 Unknown system variable` to both spellings.
    ///
    /// This is the floor the tests and `scripts/check-mysql-query-timeout.sh` assert, not the
    /// runtime gate: `applyQueryTimeout` runs the statement and reads the server's own answer,
    /// which is right for a fork, a proxy or a release no image exists for.
    static func hasStatementTimeout(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        switch flavor {
        case .mysql:
            return isAtLeast((5, 7, 8), banner: banner)
        case .mariadb:
            return isAtLeast((10, 1, 1), banner: banner)
        case .tidb, .oceanbase, .databend:
            return true
        }
    }

    /// Which account grammar this server takes. `CREATE USER ... WITH MAX_USER_CONNECTIONS`,
    /// `ALTER USER ... WITH MAX_USER_CONNECTIONS` and `ALTER USER ... IDENTIFIED BY` all arrived in
    /// MySQL 5.7.6 and MariaDB 10.2.0; measured, MySQL 5.5.62 and 5.6.51 and MariaDB 5.5.64,
    /// 10.0.38 and 10.1.48 answer `ERROR 1064` to all three.
    ///
    /// TiDB and OceanBase ignore the banner, which lies about them: OceanBase handshakes as 5.7.25,
    /// or 5.6.25 through OBProxy.
    static func accountSyntax(banner: String?, flavor: MySQLServerFlavor) -> MySQLAccountSyntax {
        switch flavor {
        case .mysql:
            return isKnownBelow((5, 7, 6), banner: banner) ? .grantUsage : .alterUser
        case .mariadb:
            return isKnownBelow((10, 2, 0), banner: banner) ? .grantUsage : .alterUser
        case .tidb, .oceanbase, .databend:
            return .alterUser
        }
    }

    /// `COLUMNS.GENERATION_EXPRESSION` arrived with generated columns: MySQL 5.7.6, MariaDB 10.2.
    /// MariaDB 10.1 has the columns but not the catalog column.
    static func hasGenerationExpression(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        switch flavor {
        case .mysql:
            return isAtLeast((5, 7, 6), banner: banner)
        case .mariadb:
            return isAtLeast((10, 2, 0), banner: banner)
        case .tidb, .oceanbase:
            return true
        case .databend:
            return false
        }
    }

    /// Whether a literal default comes back from the catalog already quoted.
    ///
    /// MariaDB began quoting `COLUMN_DEFAULT` in 10.2.7, alongside expression defaults. Before that,
    /// and on every MySQL, a literal arrives bare and is indistinguishable from an expression by its
    /// text alone. MySQL never quotes, and marks an expression `DEFAULT_GENERATED` in `EXTRA` instead.
    static func quotesColumnDefault(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        flavor.isMariaDB && isAtLeast((10, 2, 7), banner: banner)
    }
}
