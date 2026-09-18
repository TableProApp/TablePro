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

    /// The parameter list comes from information_schema.PARAMETERS, where ordinal 0 is a function's
    /// return value rather than a parameter.
    public static func routineList(schema: String) -> String {
        let schemaLiteral = escapeLiteral(schema)
        return """
            SELECT
                r.ROUTINE_NAME,
                r.ROUTINE_TYPE,
                r.DTD_IDENTIFIER,
                r.SQL_DATA_ACCESS,
                r.IS_DETERMINISTIC,
                r.SECURITY_TYPE,
                r.DEFINER,
                r.ROUTINE_SCHEMA,
                (
                    SELECT GROUP_CONCAT(
                        CONCAT_WS(' ', p.PARAMETER_MODE, p.PARAMETER_NAME, p.DTD_IDENTIFIER)
                        ORDER BY p.ORDINAL_POSITION SEPARATOR ', '
                    )
                    FROM information_schema.PARAMETERS p
                    WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA
                        AND p.SPECIFIC_NAME = r.ROUTINE_NAME
                        AND p.ROUTINE_TYPE = r.ROUTINE_TYPE
                        AND p.ORDINAL_POSITION > 0
                ) AS PARAMETER_LIST
            FROM information_schema.ROUTINES r
            WHERE r.ROUTINE_SCHEMA = '\(schemaLiteral)'
            ORDER BY r.ROUTINE_TYPE, r.ROUTINE_NAME
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

    /// A DEFINER arrives as `user@host` and both halves are identifiers, so quoting the whole
    /// string produces a name no server will accept.
    public static func quotedDefiner(_ definer: String) -> String {
        guard let separator = definer.lastIndex(of: "@") else { return quoteIdentifier(definer) }
        let user = String(definer[definer.startIndex ..< separator])
        let host = String(definer[definer.index(after: separator)...])
        return "\(quoteIdentifier(user))@\(quoteIdentifier(host))"
    }
}
