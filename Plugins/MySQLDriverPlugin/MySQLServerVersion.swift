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
nonisolated internal enum MySQLServerVersion {
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
    /// This is the floor the tests and `scripts/probes/check-mysql-query-timeout.sh` assert, not the
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

    /// What `REFERENTIAL_CONSTRAINTS` reports for a foreign key whose `CREATE TABLE` names no
    /// `ON DELETE` or `ON UPDATE`, so a key parsed out of `SHOW CREATE TABLE` reads the same as the
    /// catalog would have answered.
    ///
    /// Measured on a key declared with no action clause: MySQL 5.5.62, 5.6.51 and 5.7.44 and MariaDB
    /// 5.5.64 and 11.4.13 all answer `RESTRICT`, while MySQL 8.0.11, 8.0.12, 8.0.13, 8.0.15, 8.0.16
    /// and 8.4.11 answer `NO ACTION`.
    ///
    /// What the DDL prints was measured on one table carrying all three declarations. 5.7.44 and
    /// MariaDB 11.4.13 print an explicit `NO ACTION` and omit an explicit `RESTRICT`; 8.0.13, 8.0.15,
    /// 8.0.16 and 8.4.11 print an explicit `RESTRICT` and omit an explicit `NO ACTION`. Either way
    /// the omitted spelling is the one this returns, so the parse is exact.
    ///
    /// 8.0.11 and 8.0.12 print neither spelling, so an explicit `RESTRICT` cannot be told from a key
    /// that names no action at all and reads back as `NO ACTION`. It stays `NO ACTION` there: that is
    /// what those servers report for the omitted clause, which is the common one, and `RESTRICT`
    /// would mislabel it instead. Only the DDL path is affected, so a connection whose catalog
    /// answers is exact on those versions too.
    static func omittedForeignKeyAction(banner: String?, flavor: MySQLServerFlavor) -> String {
        guard !flavor.isMariaDB else { return "RESTRICT" }
        return isAtLeast((8, 0, 0), banner: banner) ? "NO ACTION" : "RESTRICT"
    }

    /// Whether a literal default comes back from `INFORMATION_SCHEMA.COLUMNS` already quoted.
    ///
    /// MariaDB began quoting `COLUMN_DEFAULT` in 10.2.7, alongside expression defaults. Before that,
    /// and on every MySQL, a literal arrives bare and is indistinguishable from an expression by its
    /// text alone. MySQL never quotes, and marks an expression `DEFAULT_GENERATED` in `EXTRA` instead.
    ///
    /// It describes that catalog table and nothing else. MariaDB's `SHOW FULL COLUMNS` kept the old
    /// bare form, so a `SHOW` answer is never read this way whatever the server version.
    static func quotesColumnDefault(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        flavor.isMariaDB && isAtLeast((10, 2, 7), banner: banner)
    }

    /// Whether a MariaDB default can be an expression other than `CURRENT_TIMESTAMP`, which MariaDB
    /// allows from 10.2.1. From then on its `SHOW FULL COLUMNS` reports `uuid()` and the string
    /// `'uuid()'` alike, so the bare form alone cannot recreate a default. An unreadable banner is
    /// not an old server.
    static func mariaDBDefaultsCanBeExpressions(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        flavor.isMariaDB && !isKnownBelow((10, 2, 1), banner: banner)
    }

    // MARK: - Servers before 5.5

    /// `information_schema` and `SHOW FULL TABLES` arrived in MySQL 5.0.2. Measured on 4.1.22: the
    /// catalog answers `1146` and `SHOW FULL TABLES` answers `1064`, while `SHOW TABLES` works.
    static func hasInformationSchema(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 0, 2), banner: banner, flavor: flavor)
    }

    /// `information_schema.TRIGGERS` arrived in 5.0.10, after the catalog itself.
    static func hasTriggerCatalog(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 0, 10), banner: banner, flavor: flavor)
    }

    /// `SHOW ... WHERE` arrived in 5.0.3; 4.1.22 answers `1064` and takes only `LIKE`.
    static func showAcceptsWhere(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 0, 3), banner: banner, flavor: flavor)
    }

    /// `KILL QUERY` arrived in 5.0.0, and 4.1.22 answers it with `1204`. Below that the only way to
    /// stop a statement is `KILL <id>`, which ends the session with it.
    static func canStopStatementAlone(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 0, 0), banner: banner, flavor: flavor)
    }

    /// Measured on 4.1.22: every string column of `SHOW FULL COLUMNS`, `SHOW INDEX`, `SHOW CREATE
    /// TABLE`, `SHOW TABLE STATUS` and `SHOW VARIABLES` arrives as charset 63 with `BINARY_FLAG`,
    /// although the bytes are already converted to `character_set_results`. 5.0.96 labels them utf8.
    static func labelsShowTextAsBinary(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        isLegacy(below: (5, 0, 0), banner: banner, flavor: flavor)
    }

    /// `information_schema.PARTITIONS` and `EVENTS` arrived in 5.1.6: 5.0.96 answers `1109`.
    static func hasPartitionAndEventCatalogs(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 1, 6), banner: banner, flavor: flavor)
    }

    /// `information_schema.REFERENTIAL_CONSTRAINTS` arrived in 5.1.10: 5.0.96 answers `1109`.
    static func hasReferentialConstraintsCatalog(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 1, 10), banner: banner, flavor: flavor)
    }

    /// `information_schema.PARAMETERS` arrived in 5.5.3: 5.1.73 answers `1109`, 5.5.61 answers.
    static func hasParametersCatalog(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 5, 3), banner: banner, flavor: flavor)
    }

    /// InnoDB appends its free space, and its foreign keys, to the table comment in both
    /// `SHOW TABLE STATUS` and `information_schema.TABLES`. Measured on 4.1.22 and 5.0.96 and not on
    /// 5.1.73; the 5.1 release that stopped is not established, so every server before 5.5 is read
    /// this way, and a comment without the status is left alone.
    static func appendsInnoDBStatusToComment(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        isLegacy(below: (5, 5, 0), banner: banner, flavor: flavor)
    }

    /// `CREATE USER` arrived in 5.0.2, so account management below it is `GRANT` and direct writes to
    /// the grant tables, which the Users screen does not speak.
    static func hasCreateUser(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 0, 2), banner: banner, flavor: flavor)
    }

    /// `mysql.user.max_user_connections` arrived in 5.0.3; 4.1.22 answers `1054`.
    static func hasUserConnectionLimit(banner: String?, flavor: MySQLServerFlavor) -> Bool {
        !isLegacy(below: (5, 0, 3), banner: banner, flavor: flavor)
    }

    /// Before 5.5 the server sends an error message in the charset of its error language and ignores
    /// `character_set_results` (MySQL 4.1 manual, "Character Set for Error Messages"). Measured EUC-KR
    /// with `--language=korean` on 4.1.22, 5.0.96 and 5.1.73, and UTF-8 on 5.5.61.
    ///
    /// Read from the banner alone, because the connection needs it before the flavor is resolved. No
    /// flavor that is not MySQL or MariaDB reports a version below 5.5.
    static func sendsErrorsInLanguageCharset(banner: String?) -> Bool {
        isKnownBelow((5, 5, 0), banner: banner)
    }

    /// MariaDB 5.1 to 5.3 are built on MySQL 5.1 and carry its catalog, so one set of numbers serves
    /// both. The other flavors answer with a 5.7 or 8.0 banner and their own catalogs.
    private static func isLegacy(below target: (Int, Int, Int), banner: String?, flavor: MySQLServerFlavor) -> Bool {
        switch flavor {
        case .mysql, .mariadb:
            return isKnownBelow(target, banner: banner)
        case .tidb, .oceanbase, .databend:
            return false
        }
    }
}
