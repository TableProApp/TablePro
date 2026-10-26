//
//  MySQLObjectQueries.swift
//  MySQLDriverPlugin
//
//  Catalog SQL for routines and triggers, and the rule every catalog read shares for naming the
//  database it means. Pure, so it is testable without a server.
//

import Foundation

public enum MySQLObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        mysqlEscapeStringLiteral(value)
    }

    public static func quoteIdentifier(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }

    /// The database a catalog read means.
    ///
    /// These engines have no schema layer, so every `schema:` the driver protocol hands them is a
    /// database name, and a caller that names none means the one the connection is already on. That
    /// fallback is the whole rule: an unqualified name resolves against the session's current
    /// database, so a read that drops the caller's schema silently answers about a same-named table
    /// somewhere else.
    public static func effectiveSchema(_ schema: String?, activeDatabase: String) -> String {
        guard let schema, !schema.isEmpty else { return activeDatabase }
        return schema
    }

    /// Quoting is the caller's, not this file's: Databend answers the same protocol through the same
    /// driver and escapes a backtick-bearing name by switching to double quotes, so rendering one
    /// here with the MySQL quoter would corrupt it.
    public static func qualifiedIdentifier(
        schema: String?,
        name: String,
        quote: (String) -> String
    ) -> String {
        guard let schema, !schema.isEmpty else { return quote(name) }
        return "\(quote(schema)).\(quote(name))"
    }

    public static func qualifiedIdentifier(schema: String?, name: String) -> String {
        qualifiedIdentifier(schema: schema, name: name, quote: quoteIdentifier)
    }

    // Neither MySQL's nor MariaDB's ALTER VIEW has a COMMENT clause.
    public static func takesTableComment(objectType: String) -> Bool {
        switch objectType.uppercased() {
        case "TABLE", "PARTITIONED TABLE":
            return true
        default:
            return false
        }
    }

    public static func tableCommentStatement(qualifiedTable: String, objectType: String, comment: String?) -> String? {
        guard takesTableComment(objectType: objectType) else { return nil }
        return "ALTER TABLE \(qualifiedTable) COMMENT = '\(escapeLiteral(comment ?? ""))'"
    }

    /// Lists a schema's tables, with the partition count joined in for the ones that have any.
    ///
    /// `information_schema.PARTITIONS` holds one all-null row for a table that is not partitioned,
    /// so `PARTITION_NAME IS NOT NULL` is what separates the two. A subpartitioned table repeats its
    /// partition name once per subpartition, so the count is over distinct names rather than rows.
    ///
    /// The grouping and the join both compare the name as bytes. `INFORMATION_SCHEMA` collates its
    /// identifiers case-insensitively on MySQL 5.7 and earlier and on every MariaDB measured, so on a
    /// server with `lower_case_table_names=0` a schema holding both `orders` and `Orders` would merge
    /// their counts and could label the unpartitioned one `PARTITIONED TABLE`.
    ///
    /// `CAST(... AS BINARY)` rather than the `BINARY` operator, which MySQL 8.0.27 deprecated: it
    /// raises three of Warning 1287 on every read from 8.4 on. Measured warning-free with identical
    /// rows on MySQL 5.5 to 9.7, MariaDB 5.5 to 11.4 and TiDB. `TABLE_NAME` stays in the `GROUP BY`,
    /// or `ONLY_FULL_GROUP_BY` rejects the query with 1055.
    ///
    /// `includePartitions` is false for Databend, which answers the same wire protocol through the
    /// same driver without this catalog.
    public static func tableList(schema: String, includePartitions: Bool) -> String {
        let schemaLiteral = escapeLiteral(schema)
        guard includePartitions else {
            return """
                SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COMMENT, NULL
                FROM information_schema.TABLES t
                WHERE t.TABLE_SCHEMA = '\(schemaLiteral)'
                """
        }
        return """
            SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COMMENT, p.PARTITION_COUNT
            FROM information_schema.TABLES t
            LEFT JOIN (
                SELECT TABLE_NAME AS P_TABLE_NAME, COUNT(DISTINCT PARTITION_NAME) AS PARTITION_COUNT
                FROM information_schema.PARTITIONS
                WHERE TABLE_SCHEMA = '\(schemaLiteral)' AND PARTITION_NAME IS NOT NULL
                GROUP BY CAST(TABLE_NAME AS BINARY), TABLE_NAME
            ) p ON CAST(p.P_TABLE_NAME AS BINARY) = CAST(t.TABLE_NAME AS BINARY)
            WHERE t.TABLE_SCHEMA = '\(schemaLiteral)'
            """
    }

    /// The server's own answer to which tables an account can see in a database. Unlike
    /// `information_schema`, it reports an account with no table privilege there as an access error.
    public static func showFullTables(schema: String) -> String {
        "SHOW FULL TABLES FROM \(quoteIdentifier(schema))"
    }

    /// The listing a server before 5.0.2 understands: one column of names, and every row a base
    /// table, since views arrived with 5.0.1.
    public static func showTables(schema: String) -> String {
        "SHOW TABLES FROM \(quoteIdentifier(schema))"
    }

    /// The table list read the server can answer: the catalog where it exists, then `SHOW`.
    public static func listedTables(schema: String, hasInformationSchema: Bool) -> String {
        hasInformationSchema ? showFullTables(schema: schema) : showTables(schema: schema)
    }

    /// One table's `SHOW TABLE STATUS` row. Below 5.0.3 the statement takes `LIKE` only, so the
    /// pattern escapes its wildcards and the caller still keeps only the row named exactly.
    public static func tableStatus(schema: String?, table: String, acceptsWhere: Bool) -> String {
        let from = schema.flatMap { $0.isEmpty ? nil : " FROM \(quoteIdentifier($0))" } ?? ""
        guard acceptsWhere else {
            return "SHOW TABLE STATUS\(from) LIKE '\(escapeLiteral(likePattern(matching: table)))'"
        }
        return "SHOW TABLE STATUS\(from) WHERE Name = '\(escapeLiteral(table))'"
    }

    public static func likePattern(matching name: String) -> String {
        name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Whether `information_schema` describes this database at all, in one scalar.
    ///
    /// A direct server always answers a scalar aggregate with one row. DBLE 3.23 answers it with no
    /// row at all, which is the unambiguous signal that the catalog is the proxy's own and not the
    /// database's.
    public static func catalogTableCount(schema: String) -> String {
        """
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '\(escapeLiteral(schema))'
        """
    }

    /// The columns of every foreign key in a database, or of one table's.
    ///
    /// Read on its own rather than joined to `REFERENTIAL_CONSTRAINTS`, because ShardingSphere-Proxy
    /// 5.5.3 answers any join of two `information_schema` tables with an OK packet carrying no
    /// columns while answering either read correctly alone.
    ///
    /// `ORDINAL_POSITION` in the `ORDER BY` is what puts a composite key's columns in declaration
    /// order. Without it, MariaDB 11.4.13 returns them reversed: measured on a two-column key,
    /// ordering by `CONSTRAINT_NAME` alone answered `p_tenant` then `p_id`.
    public static func foreignKeyColumns(schema: String, table: String?) -> String {
        let tablePredicate = table.map { "AND TABLE_NAME = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME,
                   REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = '\(escapeLiteral(schema))'
                \(tablePredicate)
                AND REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
            """
    }

    /// The two referential actions of every foreign key in a database, or of one table's.
    /// `TABLE_NAME` is on this catalog from MySQL 5.5 and MariaDB 5.5, so the pair names one key
    /// without a join.
    public static func referentialActions(schema: String, table: String?) -> String {
        let tablePredicate = table.map { "AND TABLE_NAME = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT TABLE_NAME, CONSTRAINT_NAME, DELETE_RULE, UPDATE_RULE
            FROM information_schema.REFERENTIAL_CONSTRAINTS
            WHERE CONSTRAINT_SCHEMA = '\(escapeLiteral(schema))'
                \(tablePredicate)
            """
    }

    /// One table's partitions, subpartitions included. A subpartition arrives as its own row
    /// carrying its parent partition's name, ordered so the parent is read before its children.
    public static func partitionList(schema: String, table: String) -> String {
        """
        SELECT PARTITION_NAME, SUBPARTITION_NAME, PARTITION_METHOD, PARTITION_DESCRIPTION,
               PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION, TABLE_ROWS
        FROM information_schema.PARTITIONS
        WHERE TABLE_SCHEMA = '\(escapeLiteral(schema))'
          AND TABLE_NAME = '\(escapeLiteral(table))'
          AND PARTITION_NAME IS NOT NULL
        ORDER BY PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION
        """
    }

    /// `SELECT @@lower_case_table_names`. Only at `0` are two database names differing in letter case
    /// two databases; at 1 and 2 the server treats them as one.
    public static let lowerCaseTableNames = "SELECT @@lower_case_table_names"

    /// MySQL 5.7 and earlier and MariaDB fill `ROUTINES`, `PARAMETERS` and `EVENTS` from every
    /// database and compare the schema name case-insensitively, so under `lower_case_table_names = 0`
    /// a read of `casedb` also answered about `CASEDB`. Measured on 5.6.51 and MariaDB 10.6.28, where
    /// `TRIGGERS`, `COLUMNS`, `STATISTICS` and `KEY_COLUMN_USAGE` answer about the exact database.
    ///
    /// The byte comparison is added to the plain one, not put in its place: on MySQL 8.4.13 the byte
    /// comparison alone turns the routine read from an index lookup into a scan of every routine on
    /// the server.
    private static func schemaMatch(_ column: String, _ schema: String, exact: Bool) -> String {
        let literal = escapeLiteral(schema)
        guard exact else { return "\(column) = '\(literal)'" }
        return "\(column) = '\(literal)' AND CAST(\(column) AS BINARY) = CAST('\(literal)' AS BINARY)"
    }

    /// A database's procedures and functions, without their parameters: `routineParameters` reads
    /// those once for the whole database, and `MySQLRoutineSignatures` says why.
    ///
    /// MariaDB lists a package as `PACKAGE` and `PACKAGE BODY` rows, which `SHOW CREATE FUNCTION`
    /// answers with 1305, so the list keeps the two standalone kinds only.
    public static func routineList(schema: String, exactSchema: Bool) -> String {
        """
        SELECT
            ROUTINE_NAME,
            ROUTINE_TYPE,
            DTD_IDENTIFIER,
            SQL_DATA_ACCESS,
            IS_DETERMINISTIC,
            SECURITY_TYPE,
            DEFINER,
            ROUTINE_SCHEMA
        FROM information_schema.ROUTINES
        WHERE \(schemaMatch("ROUTINE_SCHEMA", schema, exact: exactSchema))
          AND ROUTINE_TYPE IN ('PROCEDURE', 'FUNCTION')
        ORDER BY ROUTINE_TYPE, ROUTINE_NAME
        """
    }

    /// Every parameter of every routine in a database, in declaration order. Ordinal 0 is a
    /// function's return value rather than a parameter. The table arrived in 5.5.3.
    public static func routineParameters(schema: String, exactSchema: Bool) -> String {
        """
        SELECT SPECIFIC_SCHEMA, ROUTINE_TYPE, SPECIFIC_NAME, PARAMETER_MODE, PARAMETER_NAME, DTD_IDENTIFIER
        FROM information_schema.PARAMETERS
        WHERE \(schemaMatch("SPECIFIC_SCHEMA", schema, exact: exactSchema))
          AND ORDINAL_POSITION > 0
        ORDER BY SPECIFIC_SCHEMA, ROUTINE_TYPE, SPECIFIC_NAME, ORDINAL_POSITION
        """
    }

    public static func eventList(schema: String, exactSchema: Bool) -> String {
        """
        SELECT EVENT_NAME, EVENT_TYPE, STATUS, EVENT_SCHEMA
        FROM information_schema.EVENTS
        WHERE \(schemaMatch("EVENT_SCHEMA", schema, exact: exactSchema))
        ORDER BY EVENT_NAME
        """
    }

    /// Qualified with the schema. Unqualified, the server resolves the name against the session
    /// database instead of the one being browsed, and returns a different routine's body or none.
    public static func routineDefinition(kind: String, schema: String?, name: String) -> String {
        "SHOW CREATE \(kind) \(qualifiedIdentifier(schema: schema, name: name))"
    }

    /// One builder for both scopes: the per-table fetch adds a predicate and nothing else, so the
    /// Structure tab and the sidebar cannot disagree about a table's triggers.
    public static func triggerList(schema: String, table: String?) -> String {
        let schemaLiteral = escapeLiteral(schema)
        let tablePredicate = table.map { "AND EVENT_OBJECT_TABLE = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT
                TRIGGER_NAME,
                EVENT_OBJECT_TABLE,
                EVENT_OBJECT_SCHEMA,
                ACTION_TIMING,
                EVENT_MANIPULATION,
                ACTION_ORIENTATION,
                ACTION_STATEMENT,
                ACTION_CONDITION,
                DEFINER,
                ACTION_ORDER
            FROM information_schema.TRIGGERS
            WHERE EVENT_OBJECT_SCHEMA = '\(schemaLiteral)'
                \(tablePredicate)
            ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME
            """
    }

    /// information_schema holds the parts of a trigger but not its text, so the statement is
    /// assembled. Dropping DEFINER or the WHEN clause would produce something that looks runnable
    /// and is not the trigger the server holds.
    public static func triggerStatement(
        name: String,
        table: String,
        schema: String?,
        timing: String,
        event: String,
        orientation: String?,
        condition: String?,
        definer: String?
    ) -> String {
        var header = "CREATE"
        if let definer, !definer.isEmpty {
            header += " DEFINER = \(quotedDefiner(definer))"
        }
        header += " TRIGGER \(qualifiedIdentifier(schema: schema, name: name))"
        header += " \(timing) \(event) ON \(qualifiedIdentifier(schema: schema, name: table))"
        header += " FOR EACH \(orientation?.isEmpty == false ? orientation ?? "ROW" : "ROW")"
        if let condition, !condition.isEmpty {
            header += " WHEN (\(condition))"
        }
        return header
    }

    // The creation-settings reads select the name too: the catalog compares names case-insensitively on MySQL 5.7
    // and earlier and on MariaDB, while a trigger name is case-sensitive wherever table names are, so the driver
    // keeps only the row named exactly.

    /// The `sql_mode` the server recorded for one routine.
    public static func routineCreationSettings(schema: String, name: String, kind: String, exactSchema: Bool) -> String {
        """
        SELECT ROUTINE_NAME, SQL_MODE
        FROM information_schema.ROUTINES
        WHERE \(schemaMatch("ROUTINE_SCHEMA", schema, exact: exactSchema))
          AND ROUTINE_NAME = '\(escapeLiteral(name))'
          AND ROUTINE_TYPE = '\(escapeLiteral(kind))'
        """
    }

    /// The `sql_mode` the server recorded for one trigger.
    public static func triggerCreationSettings(schema: String, name: String) -> String {
        """
        SELECT TRIGGER_NAME, SQL_MODE
        FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA = '\(escapeLiteral(schema))'
          AND TRIGGER_NAME = '\(escapeLiteral(name))'
        """
    }

    /// The `sql_mode` and `time_zone` the server recorded for one event.
    public static func eventCreationSettings(schema: String, name: String, exactSchema: Bool) -> String {
        """
        SELECT EVENT_NAME, SQL_MODE, TIME_ZONE
        FROM information_schema.EVENTS
        WHERE \(schemaMatch("EVENT_SCHEMA", schema, exact: exactSchema))
          AND EVENT_NAME = '\(escapeLiteral(name))'
        """
    }

    /// A DEFINER arrives as `user@host` and both halves are identifiers, so quoting the whole
    /// string produces a name no server will accept.
    public static func quotedDefiner(_ definer: String) -> String {
        guard let separator = definer.lastIndex(of: "@") else { return quoteIdentifier(definer) }
        let user = String(definer[definer.startIndex ..< separator])
        let host = String(definer[definer.index(after: separator)...])
        return "\(quoteIdentifier(user))@\(quoteIdentifier(host))"
    }
}
