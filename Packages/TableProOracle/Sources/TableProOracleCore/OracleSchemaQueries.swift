import Foundation

public struct OracleTableRow: Sendable, Equatable {
    public let name: String
    public let isView: Bool
    /// Whether the table is partitioned at all, which is not the same question as how many
    /// partitions it holds: an interval-partitioned table is partitioned and reports no usable
    /// count.
    public let isPartitioned: Bool
    public let partitionCount: Int?

    public init(name: String, isView: Bool, isPartitioned: Bool = false, partitionCount: Int? = nil) {
        self.name = name
        self.isView = isView
        self.isPartitioned = isPartitioned
        self.partitionCount = partitionCount
    }
}

public struct OraclePartitionRow: Sendable, Equatable {
    public let name: String
    public let position: Int?
    public let rowCount: Int?
    public let isSubpartitioned: Bool
}

public struct OracleColumnRow: Sendable, Equatable {
    public let name: String
    public let dataType: String
    public let dataLength: String?
    public let precision: String?
    public let scale: String?
    public let isNullable: Bool
    public let isPrimaryKey: Bool

    public var displayType: String {
        OracleSchemaQueries.fullType(
            dataType: dataType,
            dataLength: dataLength,
            precision: precision,
            scale: scale
        )
    }
}

public struct OracleIndexRow: Sendable, Equatable {
    public let name: String
    public let isUnique: Bool
    public let columnName: String
    public let isPrimary: Bool
}

public struct OracleForeignKeyRow: Sendable, Equatable {
    public let constraintName: String
    public let columnName: String
    public let referencedTable: String
    public let referencedColumn: String
    public let referencedSchema: String?
    public let deleteRule: String
}

public enum OracleSchemaQueries {
    public static let ping = "SELECT 1 FROM \(OracleDictionary.dual)"
    public static let currentSchema = "SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM \(OracleDictionary.dual)"
    public static let serverVersion = "SELECT BANNER FROM \(OracleDictionary.versionView) WHERE ROWNUM = 1"
    public static let users = "SELECT USERNAME FROM \(OracleDictionary.allUsers) ORDER BY USERNAME"
    public static let commitTransaction = "COMMIT"
    public static let rollbackTransaction = "ROLLBACK"

    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public static func setCurrentSchema(_ schema: String) -> String {
        "ALTER SESSION SET CURRENT_SCHEMA = \(quoteIdentifier(schema))"
    }

    /// `ALL_PART_TABLES` carries the partition count without reading a LONG column, which this
    /// driver cannot decode. Its `INTERVAL` column is the flag for interval partitioning, where the
    /// count is a placeholder for a range the server extends on demand rather than a number of
    /// partitions that exist, so those report no count instead of a fabricated one.
    ///
    /// Being partitioned is projected separately from the count for exactly that reason: an
    /// interval-partitioned table has partitions and no count to state, and reading the missing
    /// count as "not partitioned" would take its partitions out of the tree.
    public static func tables(schema: String) -> String {
        let owner = escapeLiteral(schema)
        return """
            SELECT t.table_name, 'BASE TABLE' AS table_type,
                   CASE WHEN pt.table_name IS NULL THEN 'N' ELSE 'Y' END AS is_partitioned,
                   CASE WHEN pt.interval IS NULL THEN pt.partition_count END AS partition_count
            FROM \(OracleDictionary.allTables) t
            LEFT JOIN \(OracleDictionary.allPartTables) pt ON pt.owner = t.owner AND pt.table_name = t.table_name
            WHERE t.owner = '\(owner)'
            UNION ALL
            SELECT view_name, 'VIEW', 'N', NULL FROM \(OracleDictionary.allViews) WHERE owner = '\(owner)'
            ORDER BY 1
            """
    }

    /// One partitioned table's partitions. `HIGH_VALUE` is deliberately absent: it is a LONG
    /// column, the datatype this driver already avoids reading because OracleNIO cannot decode it,
    /// so an Oracle partition states its position rather than its bound.
    public static func partitions(schema: String, table: String) -> String {
        """
        SELECT p.partition_name, p.partition_position, p.num_rows, p.subpartition_count
        FROM \(OracleDictionary.allTabPartitions) p
        WHERE p.table_owner = '\(escapeLiteral(schema))'
          AND p.table_name = '\(escapeLiteral(table))'
        ORDER BY p.partition_position
        """
    }

    /// Every subpartition of one table, in one statement. `ALL_TAB_SUBPARTITIONS` carries the
    /// parent `PARTITION_NAME`, so the rows group in memory: asking per partition instead would be
    /// one round trip per partition, and one timeout among hundreds discards the whole answer.
    public static func subpartitions(schema: String, table: String) -> String {
        """
        SELECT s.partition_name, s.subpartition_name, s.subpartition_position, s.num_rows
        FROM \(OracleDictionary.allTabSubpartitions) s
        WHERE s.table_owner = '\(escapeLiteral(schema))'
          AND s.table_name = '\(escapeLiteral(table))'
        ORDER BY s.partition_name, s.subpartition_position
        """
    }

    public static func columns(schema: String, table: String) -> String {
        let owner = escapeLiteral(schema)
        let tableName = escapeLiteral(table)
        return """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.DATA_LENGTH,
                c.DATA_PRECISION,
                c.DATA_SCALE,
                c.NULLABLE,
                CASE WHEN cc.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
            FROM \(OracleDictionary.allTabColumns) c
            LEFT JOIN (
                SELECT acc.COLUMN_NAME
                FROM \(OracleDictionary.allConsColumns) acc
                JOIN \(OracleDictionary.allConstraints) ac ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME
                    AND acc.OWNER = ac.OWNER
                WHERE ac.CONSTRAINT_TYPE = 'P'
                    AND ac.OWNER = '\(owner)'
                    AND ac.TABLE_NAME = '\(tableName)'
            ) cc ON c.COLUMN_NAME = cc.COLUMN_NAME
            WHERE c.OWNER = '\(owner)'
              AND c.TABLE_NAME = '\(tableName)'
            ORDER BY c.COLUMN_ID
            """
    }

    public static func indexes(schema: String, table: String) -> String {
        let owner = escapeLiteral(schema)
        let tableName = escapeLiteral(table)
        return """
            SELECT i.INDEX_NAME, i.UNIQUENESS, ic.COLUMN_NAME,
                   CASE WHEN c.CONSTRAINT_TYPE = 'P' THEN 'Y' ELSE 'N' END AS IS_PK
            FROM \(OracleDictionary.allIndexes) i
            JOIN \(OracleDictionary.allIndColumns) ic ON i.INDEX_NAME = ic.INDEX_NAME AND i.OWNER = ic.INDEX_OWNER
            LEFT JOIN \(OracleDictionary.allConstraints) c ON i.INDEX_NAME = c.INDEX_NAME AND i.OWNER = c.OWNER
                AND c.CONSTRAINT_TYPE = 'P'
            WHERE i.TABLE_NAME = '\(tableName)'
              AND i.OWNER = '\(owner)'
            ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
            """
    }

    public static func foreignKeys(schema: String, table: String) -> String {
        let owner = escapeLiteral(schema)
        let tableName = escapeLiteral(table)
        return """
            SELECT
                ac.CONSTRAINT_NAME,
                acc.COLUMN_NAME,
                rc.TABLE_NAME AS REF_TABLE,
                rcc.COLUMN_NAME AS REF_COLUMN,
                ac.DELETE_RULE,
                rc.OWNER AS REF_SCHEMA
            FROM \(OracleDictionary.allConstraints) ac
            JOIN \(OracleDictionary.allConsColumns) acc ON ac.CONSTRAINT_NAME = acc.CONSTRAINT_NAME
                AND ac.OWNER = acc.OWNER
            JOIN \(OracleDictionary.allConstraints) rc ON ac.R_CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND ac.R_OWNER = rc.OWNER
            JOIN \(OracleDictionary.allConsColumns) rcc ON rc.CONSTRAINT_NAME = rcc.CONSTRAINT_NAME
                AND rc.OWNER = rcc.OWNER AND acc.POSITION = rcc.POSITION
            WHERE ac.CONSTRAINT_TYPE = 'R'
              AND ac.TABLE_NAME = '\(tableName)'
              AND ac.OWNER = '\(owner)'
            ORDER BY ac.CONSTRAINT_NAME, acc.POSITION
            """
    }

    /// Every column of every table in a schema, for the bulk structure read. Rows carry the table name first so the
    /// caller groups them.
    public static func allColumns(schema: String) -> String {
        let owner = escapeLiteral(schema)
        return """
            SELECT
                c.TABLE_NAME,
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.DATA_LENGTH,
                c.DATA_PRECISION,
                c.DATA_SCALE,
                c.NULLABLE,
                CASE WHEN cc.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
            FROM \(OracleDictionary.allTabColumns) c
            LEFT JOIN (
                SELECT acc.TABLE_NAME, acc.COLUMN_NAME
                FROM \(OracleDictionary.allConsColumns) acc
                JOIN \(OracleDictionary.allConstraints) ac ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME
                    AND acc.OWNER = ac.OWNER
                WHERE ac.CONSTRAINT_TYPE = 'P' AND ac.OWNER = '\(owner)'
            ) cc ON c.TABLE_NAME = cc.TABLE_NAME AND c.COLUMN_NAME = cc.COLUMN_NAME
            WHERE c.OWNER = '\(owner)'
            ORDER BY c.TABLE_NAME, c.COLUMN_ID
            """
    }

    /// Every foreign key of every table in a schema, for the bulk structure read. Rows carry the table name first so
    /// the caller groups them.
    public static func allForeignKeys(schema: String) -> String {
        let owner = escapeLiteral(schema)
        return """
            SELECT
                ac.TABLE_NAME,
                ac.CONSTRAINT_NAME,
                acc.COLUMN_NAME,
                rc.TABLE_NAME AS REF_TABLE,
                rcc.COLUMN_NAME AS REF_COLUMN,
                ac.DELETE_RULE,
                rc.OWNER AS REF_SCHEMA
            FROM \(OracleDictionary.allConstraints) ac
            JOIN \(OracleDictionary.allConsColumns) acc ON ac.CONSTRAINT_NAME = acc.CONSTRAINT_NAME
                AND ac.OWNER = acc.OWNER
            JOIN \(OracleDictionary.allConstraints) rc ON ac.R_CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND ac.R_OWNER = rc.OWNER
            JOIN \(OracleDictionary.allConsColumns) rcc ON rc.CONSTRAINT_NAME = rcc.CONSTRAINT_NAME
                AND rc.OWNER = rcc.OWNER AND acc.POSITION = rcc.POSITION
            WHERE ac.CONSTRAINT_TYPE = 'R' AND ac.OWNER = '\(owner)'
            ORDER BY ac.TABLE_NAME, ac.CONSTRAINT_NAME, acc.POSITION
            """
    }

    /// The name and table count of every schema, for the databases list. The size is read separately with
    /// ``schemaSegmentSizes()`` because it needs a dictionary view a non-DBA cannot read, and joining it here would
    /// fail the whole statement for such a reader.
    public static let databaseSummaries = """
        SELECT u.USERNAME,
               NVL(t.table_count, 0) AS table_count
        FROM \(OracleDictionary.allUsers) u
        LEFT JOIN (
            SELECT OWNER, COUNT(*) AS table_count FROM \(OracleDictionary.allTables) GROUP BY OWNER
        ) t ON u.USERNAME = t.OWNER
        ORDER BY u.USERNAME
        """

    /// The total segment bytes of every schema. `DBA_SEGMENTS` needs `SELECT` on the DBA views, so the caller runs this
    /// best-effort and leaves the sizes blank when it is refused. `ALL_SEGMENTS` does not exist on Oracle (ORA-00942
    /// even as `SYSTEM`), so it is never used.
    public static let schemaSegmentSizes = """
        SELECT OWNER, SUM(BYTES) AS size_bytes FROM \(OracleDictionary.dbaSegments) GROUP BY OWNER
        """

    /// The table count of one schema.
    public static func databaseTableCount(schema: String) -> String {
        "SELECT COUNT(*) FROM \(OracleDictionary.allTables) WHERE OWNER = '\(escapeLiteral(schema))'"
    }

    /// The row count and comment of one table, without its size. The size is read separately with
    /// ``segmentSize(schema:table:ownedByCurrentSchema:)``.
    public static func tableMetadata(schema: String, table: String) -> String {
        """
        SELECT t.NUM_ROWS, tc.COMMENTS
        FROM \(OracleDictionary.allTables) t
        LEFT JOIN \(OracleDictionary.allTabComments) tc ON t.TABLE_NAME = tc.TABLE_NAME AND t.OWNER = tc.OWNER
        WHERE t.TABLE_NAME = '\(escapeLiteral(table))' AND t.OWNER = '\(escapeLiteral(schema))'
        """
    }

    /// The comment of one view, the fallback when ``tableMetadata(schema:table:)`` finds no base table.
    public static func viewComment(schema: String, view: String) -> String {
        """
        SELECT tc.COMMENTS
        FROM \(OracleDictionary.allTabComments) tc
        WHERE tc.TABLE_NAME = '\(escapeLiteral(view))' AND tc.OWNER = '\(escapeLiteral(schema))'
        """
    }

    /// The total segment bytes of one table or schema.
    ///
    /// A reader can always see its own schema's segments through `USER_SEGMENTS`, so the own-schema case avoids needing
    /// the DBA privilege `DBA_SEGMENTS` wants. `ALL_SEGMENTS` does not exist, so it is never used, and the caller runs
    /// this best-effort and leaves the size blank when a cross-schema read is refused.
    public static func segmentSize(schema: String, table: String?, ownedByCurrentSchema: Bool) -> String {
        let filter = table.map { "SEGMENT_NAME = '\(escapeLiteral($0))'" } ?? "1 = 1"
        if ownedByCurrentSchema {
            return "SELECT NVL(SUM(BYTES), 0) FROM \(OracleDictionary.userSegments) WHERE \(filter)"
        }
        let owner = escapeLiteral(schema)
        let scoped = table.map { "SEGMENT_NAME = '\(escapeLiteral($0))' AND " } ?? ""
        return "SELECT NVL(SUM(BYTES), 0) FROM \(OracleDictionary.dbaSegments) WHERE \(scoped)OWNER = '\(owner)'"
    }

    /// The view's `SELECT` text, without the LONG `TEXT` column OracleNIO cannot decode. `TEXT_VC` is `VARCHAR2(4000)`.
    public static func viewDefinition(schema: String, view: String) -> String {
        """
        SELECT TEXT_VC FROM \(OracleDictionary.allViews) \
        WHERE VIEW_NAME = '\(escapeLiteral(view))' AND OWNER = '\(escapeLiteral(schema))'
        """
    }

    /// The tables of one schema for the object tree's bulk metadata read.
    public static func allTablesMetadata(schema: String) -> String {
        """
        SELECT
            OWNER as schema_name,
            TABLE_NAME as name,
            'TABLE' as kind,
            NUM_ROWS as estimated_rows
        FROM \(OracleDictionary.allTables)
        WHERE OWNER = '\(escapeLiteral(schema))'
        ORDER BY TABLE_NAME
        """
    }

    /// The column names and types of one table, used to recover the header of an empty result set.
    public static func columnNamesAndTypes(schema: String, table: String) -> String {
        """
        SELECT COLUMN_NAME, DATA_TYPE FROM \(OracleDictionary.allTabColumns) \
        WHERE OWNER = '\(escapeLiteral(schema))' \
        AND TABLE_NAME = '\(escapeLiteral(table))' \
        ORDER BY COLUMN_ID
        """
    }

    public static func parseTableRow(_ row: [OracleRawCell]) -> OracleTableRow? {
        guard let name = row[safe: 0]?.stringValue else { return nil }
        return OracleTableRow(
            name: name,
            isView: row[safe: 1]?.stringValue == "VIEW",
            isPartitioned: row[safe: 2]?.stringValue == "Y",
            partitionCount: row[safe: 3]?.stringValue.flatMap(Int.init)
        )
    }

    public static func parsePartitionRow(_ row: [OracleRawCell]) -> OraclePartitionRow? {
        guard let name = row[safe: 0]?.stringValue else { return nil }
        return OraclePartitionRow(
            name: name,
            position: row[safe: 1]?.stringValue.flatMap(Int.init),
            rowCount: row[safe: 2]?.stringValue.flatMap(Int.init),
            isSubpartitioned: (row[safe: 3]?.stringValue.flatMap(Int.init) ?? 0) > 0
        )
    }

    /// The parent partition's name comes first, because the caller groups by it.
    public static func parseSubpartitionRow(_ row: [OracleRawCell]) -> (parent: String, row: OraclePartitionRow)? {
        guard let parent = row[safe: 0]?.stringValue, let name = row[safe: 1]?.stringValue else { return nil }
        return (
            parent,
            OraclePartitionRow(
                name: name,
                position: row[safe: 2]?.stringValue.flatMap(Int.init),
                rowCount: row[safe: 3]?.stringValue.flatMap(Int.init),
                isSubpartitioned: false
            )
        )
    }

    public static func parseColumnRow(_ row: [OracleRawCell]) -> OracleColumnRow? {
        guard let name = row[safe: 0]?.stringValue else { return nil }
        return OracleColumnRow(
            name: name,
            dataType: (row[safe: 1]?.stringValue)?.lowercased() ?? "varchar2",
            dataLength: row[safe: 2]?.stringValue,
            precision: row[safe: 3]?.stringValue,
            scale: row[safe: 4]?.stringValue,
            isNullable: row[safe: 5]?.stringValue == "Y",
            isPrimaryKey: row[safe: 6]?.stringValue == "Y"
        )
    }

    public static func parseIndexRow(_ row: [OracleRawCell]) -> OracleIndexRow? {
        guard let name = row[safe: 0]?.stringValue,
              let columnName = row[safe: 2]?.stringValue else { return nil }
        return OracleIndexRow(
            name: name,
            isUnique: row[safe: 1]?.stringValue == "UNIQUE",
            columnName: columnName,
            isPrimary: row[safe: 3]?.stringValue == "Y"
        )
    }

    public static func parseForeignKeyRow(_ row: [OracleRawCell]) -> OracleForeignKeyRow? {
        guard let constraintName = row[safe: 0]?.stringValue,
              let columnName = row[safe: 1]?.stringValue,
              let referencedTable = row[safe: 2]?.stringValue,
              let referencedColumn = row[safe: 3]?.stringValue else { return nil }
        return OracleForeignKeyRow(
            constraintName: constraintName,
            columnName: columnName,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn,
            referencedSchema: row[safe: 5]?.stringValue,
            deleteRule: row[safe: 4]?.stringValue ?? "NO ACTION"
        )
    }

    public static func fullType(
        dataType: String,
        dataLength: String?,
        precision: String?,
        scale: String?
    ) -> String {
        let fixedTypes: Set<String> = [
            "date", "clob", "nclob", "blob", "bfile", "long", "long raw",
            "rowid", "urowid", "binary_float", "binary_double", "xmltype"
        ]
        if fixedTypes.contains(dataType) {
            return dataType
        }
        if dataType == "number" {
            guard let precision, let precisionValue = Int(precision) else { return dataType }
            if let scale, let scaleValue = Int(scale), scaleValue > 0 {
                return "number(\(precisionValue),\(scaleValue))"
            }
            return "number(\(precisionValue))"
        }
        if let dataLength, let lengthValue = Int(dataLength), lengthValue > 0 {
            return "\(dataType)(\(lengthValue))"
        }
        return dataType
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
