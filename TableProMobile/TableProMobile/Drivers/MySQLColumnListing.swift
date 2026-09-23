import Foundation
import TableProDatabase
import TableProModels

/// The columns `SHOW FULL COLUMNS` lists, each default read the way the Mac app reads it.
nonisolated internal enum MySQLColumnListing {
    enum DefaultSource: Equatable, Sendable {
        /// `SHOW FULL COLUMNS` alone, in its bare form: MySQL, TiDB, and a MariaDB before 10.2.7. The
        /// Mac app also reads `SHOW CREATE TABLE` where that form is ambiguous, and this does not.
        case showFullColumns
        /// `INFORMATION_SCHEMA.COLUMNS` in the quoted form a MariaDB uses from 10.2.7, the only read
        /// there that tells an expression default from a string.
        case quotedCatalog
        /// `INFORMATION_SCHEMA.COLUMNS`, which OceanBase answers right for a view where its `SHOW FULL
        /// COLUMNS` does not.
        case oceanBaseCatalog
        /// The server's own text. Databend's defaults follow none of MySQL's catalog rules.
        case asReported
    }

    static func defaultSource(flavor: MySQLServerFlavor, banner: String?) -> DefaultSource {
        if flavor.isDatabend { return .asReported }
        if flavor.isOceanBase { return .oceanBaseCatalog }
        guard MySQLServerVersion.quotesColumnDefault(banner: banner, flavor: flavor) else { return .showFullColumns }
        return .quotedCatalog
    }

    /// The catalog read for one table's defaults, or nil when `SHOW FULL COLUMNS` is the only source.
    ///
    /// It filters on `DATABASE()` because the unqualified `SHOW FULL COLUMNS` reads the session's
    /// database, and the two answers are matched by column name alone.
    static func catalogDefaultsQuery(table: String, source: DefaultSource) -> String? {
        switch source {
        case .quotedCatalog, .oceanBaseCatalog:
            return """
                SELECT COLUMN_NAME, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(SQLEscaping.backslashStringLiteral(table))'
                """
        case .showFullColumns, .asReported:
            return nil
        }
    }

    static func catalogDefaults(fromRows rows: [[String?]], source: DefaultSource) -> [String: MySQLCatalogDefault] {
        var defaults: [String: MySQLCatalogDefault] = [:]
        for row in rows {
            guard row.count >= 2, let name = row[0] else { continue }
            defaults[name] = source == .quotedCatalog ? .quoted(row[1]) : .bare(row[1])
        }
        return defaults
    }

    static func columns(
        fromShowFullColumns rows: [[String?]],
        catalogDefaults: [String: MySQLCatalogDefault],
        source: DefaultSource
    ) -> [ColumnInfo] {
        rows.enumerated().compactMap { index, row in
            guard row.count >= 9, let name = row[0], let dataType = row[1] else { return nil }
            let isNullable = row[3]?.uppercased() == "YES"
            let extra = row[6]
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: row[4]?.uppercased().contains("PRI") == true,
                isNullable: isNullable,
                defaultValue: columnDefault(
                    row[5],
                    catalog: catalogDefaults[name],
                    source: source,
                    column: name,
                    extra: extra,
                    dataType: dataType,
                    isNullable: isNullable
                ),
                comment: row[8],
                characterMaxLength: nil,
                ordinalPosition: index,
                isAutoIncrement: ColumnMetadataRules.mySQLIsAutoIncrement(extra: extra),
                isGenerated: ColumnMetadataRules.mySQLIsGenerated(extra: extra)
            )
        }
    }

    private static func columnDefault(
        _ shown: String?,
        catalog: MySQLCatalogDefault?,
        source: DefaultSource,
        column: String,
        extra: String?,
        dataType: String,
        isNullable: Bool
    ) -> String? {
        switch source {
        case .asReported:
            return shown
        case .oceanBaseCatalog:
            return OceanBaseColumnDefaults.columnDefault(
                (catalog ?? .bare(shown)).value, extra: extra, dataType: dataType, isNullable: isNullable
            )
        case .showFullColumns, .quotedCatalog:
            return mysqlShowColumnsDefault(
                shown,
                catalog: catalog,
                createTable: nil,
                column: column,
                extra: extra,
                dataType: dataType,
                isNullable: isNullable
            )
        }
    }
}
