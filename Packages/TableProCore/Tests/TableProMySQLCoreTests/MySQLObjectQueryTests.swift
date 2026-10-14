import Foundation
import Testing

@testable import TableProMySQLCore

struct MySQLObjectQueryTests {
    @Test("The DDL statement is schema-qualified")
    func routineDefinitionIsQualified() {
        let sql = MySQLObjectQueries.routineDefinition(kind: "PROCEDURE", schema: "analytics", name: "cleanup")
        #expect(sql == "SHOW CREATE PROCEDURE `analytics`.`cleanup`")
    }

    /// Unqualified, the server resolves the name against the session database, so browsing one
    /// database and opening another's routine returned a different routine's body.
    @Test("A nil schema is the only case that falls back to an unqualified name")
    func unqualifiedOnlyWithoutSchema() {
        let sql = MySQLObjectQueries.routineDefinition(kind: "FUNCTION", schema: nil, name: "f")
        #expect(sql == "SHOW CREATE FUNCTION `f`")
    }

    @Test("The parameter list excludes a function's return row")
    func parameterListSkipsOrdinalZero() {
        let sql = MySQLObjectQueries.routineList(schema: "app")
        #expect(sql.contains("p.ORDINAL_POSITION > 0"))
        #expect(sql.contains("information_schema.PARAMETERS"))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let all = MySQLObjectQueries.triggerList(schema: "app", table: nil)
        let one = MySQLObjectQueries.triggerList(schema: "app", table: "orders")
        #expect(!all.contains("EVENT_OBJECT_TABLE ="))
        #expect(one.contains("EVENT_OBJECT_TABLE = 'orders'"))
        #expect(all.contains("ACTION_CONDITION"))
        #expect(all.contains("DEFINER"))
    }

    /// Dropping DEFINER or the WHEN clause produces something that looks runnable and is not the
    /// trigger the server holds.
    @Test("The assembled statement keeps the definer and the when clause")
    func triggerStatementKeepsDefinerAndCondition() {
        let statement = MySQLObjectQueries.triggerStatement(
            name: "audit", table: "orders", schema: "app",
            timing: "BEFORE", event: "INSERT", orientation: "ROW",
            condition: "NEW.total > 0", definer: "root@localhost"
        )
        #expect(statement.contains("DEFINER = `root`@`localhost`"))
        #expect(statement.contains("WHEN (NEW.total > 0)"))
        #expect(statement.contains("`app`.`audit`"))
        #expect(statement.contains("ON `app`.`orders`"))
        #expect(statement.contains("FOR EACH ROW"))
    }

    @Test("A definer is quoted as two identifiers, not one")
    func definerIsQuotedInTwoParts() {
        #expect(MySQLObjectQueries.quotedDefiner("root@localhost") == "`root`@`localhost`")
        #expect(MySQLObjectQueries.quotedDefiner("a@b@c") == "`a@b`@`c`")
        #expect(MySQLObjectQueries.quotedDefiner("plain") == "`plain`")
    }

    @Test("A quote in a schema or table is escaped")
    func literalsAreEscaped() {
        #expect(MySQLObjectQueries.routineList(schema: "it's").contains("'it''s'"))
        #expect(MySQLObjectQueries.triggerList(schema: "app", table: "o'brien").contains("'o''brien'"))
        #expect(MySQLObjectQueries.catalogTableCount(schema: "o'brien").contains("'o''brien'"))
        #expect(MySQLObjectQueries.foreignKeyColumns(schema: "o'brien", table: nil).contains("'o''brien'"))
        #expect(MySQLObjectQueries.referentialActions(schema: "o'brien", table: nil).contains("'o''brien'"))
    }

    /// Ordering by `CONSTRAINT_NAME` alone left the order to the server. Measured on MariaDB
    /// 11.4.13, a two-column key came back as `p_tenant` then `p_id`, which the structure editor
    /// and every comparison then read as the declaration order.
    @Test("The foreign key column read ends its ordering at ORDINAL_POSITION")
    func foreignKeyColumnsOrderByOrdinalPosition() {
        let sql = MySQLObjectQueries.foreignKeyColumns(schema: "app", table: nil)
        #expect(sql.hasSuffix("ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION"))
        #expect(sql.contains("REFERENCED_TABLE_NAME IS NOT NULL"))
        #expect(sql.contains("REFERENCED_TABLE_SCHEMA"))
    }

    /// ShardingSphere-Proxy 5.5.3 answers any join of two `information_schema` tables with an OK
    /// packet carrying no columns, and answers each of these two reads correctly on its own.
    @Test("Neither foreign key read joins a second catalog")
    func foreignKeyReadsAreUnjoined() {
        let columns = MySQLObjectQueries.foreignKeyColumns(schema: "app", table: nil)
        let actions = MySQLObjectQueries.referentialActions(schema: "app", table: nil)

        #expect(!columns.uppercased().contains(" JOIN "))
        #expect(!actions.uppercased().contains(" JOIN "))
        #expect(columns.contains("information_schema.KEY_COLUMN_USAGE"))
        #expect(actions.contains("information_schema.REFERENTIAL_CONSTRAINTS"))
        #expect(actions.contains("CONSTRAINT_SCHEMA = 'app'"))
        #expect(actions.contains("DELETE_RULE"))
        #expect(actions.contains("UPDATE_RULE"))
    }

    @Test("The table filter is the only difference between the two foreign key scopes")
    func foreignKeyScopesShareOneBuilder() {
        #expect(!MySQLObjectQueries.foreignKeyColumns(schema: "app", table: nil).contains("TABLE_NAME = '"))
        #expect(MySQLObjectQueries.foreignKeyColumns(schema: "app", table: "orders").contains("TABLE_NAME = 'orders'"))
        #expect(!MySQLObjectQueries.referentialActions(schema: "app", table: nil).contains("TABLE_NAME = '"))
        #expect(
            MySQLObjectQueries.referentialActions(schema: "app", table: "orders").contains("TABLE_NAME = 'orders'")
        )
    }

    /// One scalar, so a server that answers it with no row at all is telling the driver its catalog
    /// is not this database's: measured on DBLE 3.23, where a direct MySQL always answers one row.
    @Test("The visibility probe is a single scalar count over one catalog")
    func catalogTableCountIsOneScalar() {
        let sql = MySQLObjectQueries.catalogTableCount(schema: "app")
        #expect(sql.contains("SELECT COUNT(*)"))
        #expect(sql.contains("information_schema.TABLES"))
        #expect(sql.contains("TABLE_SCHEMA = 'app'"))
        #expect(!sql.uppercased().contains(" JOIN "))
    }

    @Test("A backtick in an identifier is doubled")
    func identifiersAreQuoted() {
        #expect(MySQLObjectQueries.quoteIdentifier("we`ird") == "`we``ird`")
    }

    @Test("SHOW FULL TABLES names its database as a quoted identifier")
    func showFullTablesQuotesTheDatabase() {
        #expect(MySQLObjectQueries.showFullTables(schema: "app") == "SHOW FULL TABLES FROM `app`")
        #expect(MySQLObjectQueries.showFullTables(schema: "we`ird") == "SHOW FULL TABLES FROM `we``ird`")
    }

    /// A caller that names no database means the one the connection is on. Dropping the one it did
    /// name is what made a read about another database answer about the session's.
    @Test("A named schema wins over the active database, and only a missing one falls back")
    func effectiveSchemaPrefersTheNamedDatabase() {
        #expect(MySQLObjectQueries.effectiveSchema("crm", activeDatabase: "app") == "crm")
        #expect(MySQLObjectQueries.effectiveSchema(nil, activeDatabase: "app") == "app")
        #expect(MySQLObjectQueries.effectiveSchema("", activeDatabase: "app") == "app")
    }

    /// A connection with no database selected has nothing to qualify against, and MySQL takes no
    /// empty qualifier, so the bare name is the only form left.
    @Test("With no database selected the name stays unqualified")
    func effectiveSchemaIsEmptyWithoutADatabase() {
        let resolved = MySQLObjectQueries.effectiveSchema(nil, activeDatabase: "")
        #expect(resolved.isEmpty)
        #expect(MySQLObjectQueries.qualifiedIdentifier(schema: resolved, name: "t") == "`t`")
    }

    /// Databend answers the same driver protocol and escapes a backtick-bearing name by switching to
    /// double quotes, so a catalog statement must qualify with the caller's quoter, not this one's.
    @Test("The qualifier is rendered with the quoter the caller passes")
    func qualifiedIdentifierUsesTheCallersQuoter() {
        let shouty: (String) -> String = { "<\($0)>" }
        #expect(MySQLObjectQueries.qualifiedIdentifier(schema: "crm", name: "t", quote: shouty) == "<crm>.<t>")
        #expect(MySQLObjectQueries.qualifiedIdentifier(schema: nil, name: "t", quote: shouty) == "<t>")
        #expect(MySQLObjectQueries.qualifiedIdentifier(schema: "crm", name: "t") == "`crm`.`t`")
    }

    /// A backslash is an escape character to MySQL unless NO_BACKSLASH_ESCAPES is set, so a literal
    /// that only doubles the quote leaves a database name ending in one able to escape its own
    /// closing quote.
    @Test("A literal escapes the backslash as well as the quote")
    func literalsEscapeBackslashes() {
        #expect(MySQLObjectQueries.escapeLiteral("a\\") == "a\\\\")
        #expect(MySQLObjectQueries.escapeLiteral("it's") == "it''s")
    }

    /// Measured on 4.1.22: `SHOW FULL TABLES` answers 1064 and `SHOW TABLES` lists the names.
    @Test("A server without the catalog lists its tables with SHOW TABLES")
    func legacyTableListing() {
        #expect(MySQLObjectQueries.showTables(schema: "ju_mijuit_new") == "SHOW TABLES FROM `ju_mijuit_new`")
        #expect(MySQLObjectQueries.showTables(schema: "we`ird") == "SHOW TABLES FROM `we``ird`")
        #expect(MySQLObjectQueries.listedTables(schema: "app", hasInformationSchema: true) == "SHOW FULL TABLES FROM `app`")
        #expect(MySQLObjectQueries.listedTables(schema: "app", hasInformationSchema: false) == "SHOW TABLES FROM `app`")
    }

    /// Measured on 4.1.22: `SHOW TABLE STATUS ... WHERE` answers 1064 and `LIKE` reads the row.
    @Test("Before 5.0.3 the status read names its table with LIKE")
    func tableStatusUsesLikeWithoutWhere() {
        #expect(
            MySQLObjectQueries.tableStatus(schema: "ju_mijuit_new", table: "apcust", acceptsWhere: false)
                == "SHOW TABLE STATUS FROM `ju_mijuit_new` LIKE 'apcust'"
        )
        #expect(
            MySQLObjectQueries.tableStatus(schema: "ju_mijuit_new", table: "apcust", acceptsWhere: true)
                == "SHOW TABLE STATUS FROM `ju_mijuit_new` WHERE Name = 'apcust'"
        )
        #expect(MySQLObjectQueries.tableStatus(schema: nil, table: "apcust", acceptsWhere: false) == "SHOW TABLE STATUS LIKE 'apcust'")
        #expect(MySQLObjectQueries.tableStatus(schema: "", table: "apcust", acceptsWhere: true) == "SHOW TABLE STATUS WHERE Name = 'apcust'")
    }

    @Test("A LIKE pattern escapes its wildcards and the backslash, and nothing else")
    func likePatternEscapesWildcards() {
        #expect(MySQLObjectQueries.likePattern(matching: #"a\b%c_d"#) == #"a\\b\%c\_d"#)
        #expect(MySQLObjectQueries.likePattern(matching: "it's `t`") == "it's `t`")
    }

    @Test("The LIKE pattern is escaped again as a literal, and the database as an identifier")
    func tableStatusEscapesHostileNames() {
        #expect(
            MySQLObjectQueries.tableStatus(schema: "ju_mijuit_new", table: "apcust_send_history", acceptsWhere: false)
                == #"SHOW TABLE STATUS FROM `ju_mijuit_new` LIKE 'apcust\\_send\\_history'"#
        )
        #expect(
            MySQLObjectQueries.tableStatus(schema: "we`ird", table: #"a\b%c_d'e"#, acceptsWhere: false)
                == #"SHOW TABLE STATUS FROM `we``ird` LIKE 'a\\\\b\\%c\\_d''e'"#
        )
        #expect(
            MySQLObjectQueries.tableStatus(schema: "we`ird", table: #"a\b%c_d'e"#, acceptsWhere: true)
                == #"SHOW TABLE STATUS FROM `we``ird` WHERE Name = 'a\\b%c_d''e'"#
        )
    }

    /// `information_schema.PARAMETERS` arrived in 5.5.3; 5.1.73 answers 1109.
    @Test("Without the PARAMETERS catalog the routine list keeps its shape with a NULL parameter list")
    func routineListWithoutParameters() {
        let legacy = MySQLObjectQueries.routineList(schema: "app", includesParameters: false)

        #expect(legacy.contains("NULL AS PARAMETER_LIST"))
        #expect(!legacy.contains("information_schema.PARAMETERS"))
        #expect(legacy.contains("FROM information_schema.ROUTINES r"))
        #expect(legacy.contains("WHERE r.ROUTINE_SCHEMA = 'app'"))
        #expect(MySQLObjectQueries.routineList(schema: "app", includesParameters: true).contains("information_schema.PARAMETERS"))
    }
}
