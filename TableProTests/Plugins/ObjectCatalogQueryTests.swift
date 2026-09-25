//
//  ObjectCatalogQueryTests.swift
//  TableProTests
//
//  The catalog SQL each engine uses to list routines and triggers and to read their source.
//

import Foundation
import Testing

@testable import TablePro

struct PostgreSQLObjectQueryTests {
    /// information_schema.routines shows only what the caller has a privilege on and repeats a
    /// name once per overload, which is what produced duplicate rows and an arbitrary definition.
    @Test("Routine listing reads pg_proc, never information_schema")
    func routineListReadsPgProc() {
        let sql = PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(160_000))
        #expect(sql.contains("pg_catalog.pg_proc"))
        #expect(!sql.contains("information_schema"))
        #expect(sql.contains("p.oid::text"))
        #expect(sql.contains("pg_get_function_identity_arguments"))
    }

    /// `PQserverVersion` is 0 for a handle that has not connected. Reading that as pre-11 emitted
    /// `proisagg`, which PostgreSQL 11 dropped, and failed the listing on every current server.
    @Test("An unknown server version reads as modern, not ancient")
    func unknownVersionIsModern() {
        #expect(PostgreSQLCapabilities.assumingModernWhenUnknown(0).hasProcedureKind)
        #expect(PostgreSQLCapabilities(serverVersion: 170_000).hasProcedureKind)
        #expect(!PostgreSQLCapabilities(serverVersion: 100_000).hasProcedureKind)
        #expect(!PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(0))
            .contains("proisagg"))
    }

    @Test("Aggregates and window functions are excluded because pg_get_functiondef raises on them")
    func aggregatesExcluded() {
        let modern = PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(160_000))
        #expect(modern.contains("p.prokind IN ('f', 'p')"))

        let legacy = PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(100_000))
        #expect(legacy.contains("NOT p.proisagg AND NOT p.proiswindow"))
        #expect(!legacy.contains("prokind IN"))
    }

    @Test("The DDL fetch addresses one oid, so an overload cannot resolve to a sibling")
    func routineDefinitionIsByOid() {
        let sql = PostgreSQLObjectQueries.routineDefinition(identity: "16401")
        #expect(sql.contains("'16401'::oid"))
        #expect(!sql.contains("LIMIT 1"))
    }

    @Test("A name-addressed fallback still predicates on the argument list")
    func routineDefinitionByNameUsesArguments() {
        let sql = PostgreSQLObjectQueries.routineDefinitionByName(
            name: "transform", schema: "public", arguments: "(geometry, integer)"
        )
        #expect(sql.contains("p.proname = 'transform'"))
        #expect(sql.contains("= '(geometry, integer)'"))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let all = PostgreSQLObjectQueries.triggerList(schema: "public", table: nil)
        let one = PostgreSQLObjectQueries.triggerList(schema: "public", table: "orders")
        #expect(all.contains("pg_catalog.pg_trigger"))
        #expect(!all.contains("c.relname ="))
        #expect(one.contains("c.relname = 'orders'"))
        #expect(one.contains("pg_catalog.pg_get_triggerdef"))
    }

    @Test("Trigger events are joined with concat_ws, which 9.1 has and array_remove does not")
    func triggerEventsUseConcatWs() {
        let sql = PostgreSQLObjectQueries.triggerList(schema: "public", table: nil)
        #expect(sql.contains("concat_ws(' OR ',"))
        #expect(!sql.contains("array_remove"))
        #expect(!sql.contains("array_to_string"))
    }

    @Test("A quote in a name or schema is escaped in every query")
    func literalsAreEscaped() {
        let list = PostgreSQLObjectQueries.routineList(schema: "it's", capabilities: .assumingModernWhenUnknown(160_000))
        #expect(list.contains("'it''s'"))

        let byName = PostgreSQLObjectQueries.routineDefinitionByName(
            name: "x'; DROP TABLE t; --", schema: "public", arguments: nil
        )
        #expect(byName.contains("'x''; DROP TABLE t; --'"))

        let triggers = PostgreSQLObjectQueries.triggerList(schema: "public", table: "o'brien")
        #expect(triggers.contains("'o''brien'"))
    }

    @Test("A backslash before a quote in a name becomes an E'' literal in every query")
    func backslashNamesUseEscapeStringLiterals() {
        let hostile = "a\\'; DROP TABLE victim; --"
        let expected = "E'a\\\\''; DROP TABLE victim; --'"

        let list = PostgreSQLObjectQueries.routineList(
            schema: hostile, capabilities: .assumingModernWhenUnknown(160_000)
        )
        #expect(list.contains("n.nspname = \(expected)"))

        let byName = PostgreSQLObjectQueries.routineDefinitionByName(
            name: hostile, schema: hostile, arguments: hostile
        )
        #expect(byName.contains("p.proname = \(expected)"))
        #expect(byName.contains("n.nspname = \(expected)"))
        #expect(byName.contains("')' = \(expected)"))

        let triggers = PostgreSQLObjectQueries.triggerList(schema: hostile, table: hostile)
        #expect(triggers.contains("c.relname = \(expected)"))
        #expect(triggers.contains("n.nspname = \(expected)"))
    }
}

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
}

struct MSSQLObjectQueryTests {
    /// INFORMATION_SCHEMA.ROUTINES.ROUTINE_DEFINITION is nvarchar(4000) and silently truncates,
    /// which looks like a procedure that ends mid-statement.
    @Test("Routine source comes from sys.sql_modules, never ROUTINE_DEFINITION")
    func routineSourceAvoidsInformationSchema() {
        let list = MSSQLObjectQueries.routineList(schema: "dbo")
        let definition = MSSQLObjectQueries.routineDefinition(schema: "dbo", name: "p")
        #expect(list.contains("sys.sql_modules"))
        #expect(definition.contains("sys.sql_modules"))
        #expect(!list.contains("ROUTINE_DEFINITION"))
        #expect(!definition.contains("ROUTINE_DEFINITION"))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let all = MSSQLObjectQueries.triggerList(schema: "dbo", table: nil)
        let one = MSSQLObjectQueries.triggerList(schema: "dbo", table: "Orders")
        #expect(!all.contains("parent.name ="))
        #expect(one.contains("parent.name = N'Orders'"))
        #expect(all.contains("sys.trigger_events"))
    }

    @Test("Object types map to the two routine kinds")
    func objectTypeMapping() {
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "P ") == "PROCEDURE")
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "FN") == "FUNCTION")
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "IF") == "FUNCTION")
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "TF") == "FUNCTION")
    }

    @Test("A quote in a schema or table is escaped")
    func literalsAreEscaped() {
        #expect(MSSQLObjectQueries.routineList(schema: "it's").contains("N'it''s'"))
        #expect(MSSQLObjectQueries.triggerList(schema: "dbo", table: "o'brien").contains("N'o''brien'"))
    }

    @Test("A non-ASCII schema, routine or table name is an nvarchar literal")
    func catalogNamesAreNationalLiterals() {
        #expect(MSSQLObjectQueries.routineList(schema: "販売").contains("s.name = N'販売'"))
        let definition = MSSQLObjectQueries.routineDefinition(schema: "販売", name: "集計")
        #expect(definition.contains("s.name = N'販売' AND o.name = N'集計'"))
        let triggers = MSSQLObjectQueries.triggerList(schema: "販売", table: "注文")
        #expect(triggers.contains("s.name = N'販売'"))
        #expect(triggers.contains("parent.name = N'注文'"))
    }

    @Test("Fixed catalog type codes stay plain literals")
    func catalogTypeCodesStayPlain() {
        #expect(MSSQLObjectQueries.routineList(schema: "dbo")
            .contains("o.type IN ('P', 'PC', 'X', 'FN', 'IF', 'TF', 'FS', 'FT', 'AF')"))
    }

    /// A database with CLR routines listed fewer than it held, with nothing saying so.
    @Test("CLR and extended routines are listed alongside the T-SQL ones")
    func clrRoutinesAreListed() {
        for code in ["PC", "FS", "FT", "AF", "X"] {
            #expect(MSSQLObjectQueries.routineObjectTypes.contains(code))
        }
    }

    @Test("Every procedure code reads as a procedure and every function code as a function")
    func objectTypeMappingCoversClr() {
        for code in ["P ", "PC", "X "] {
            #expect(MSSQLObjectQueries.routineKind(forObjectType: code) == "PROCEDURE")
        }
        for code in ["FN", "IF", "TF", "FS", "FT", "AF"] {
            #expect(MSSQLObjectQueries.routineKind(forObjectType: code) == "FUNCTION")
        }
    }

    /// Measured on SQL Server 2022: a caller with only SELECT and EXECUTE still sees the
    /// sys.sql_modules row with a NULL definition, exactly as WITH ENCRYPTION does. Only
    /// OBJECTPROPERTY tells the two apart, and it answers for that caller too.
    @Test("Encryption is read from OBJECTPROPERTY, not from a missing definition")
    func encryptionIsNotInferredFromNullDefinition() {
        let list = MSSQLObjectQueries.routineList(schema: "dbo")
        #expect(list.contains("OBJECTPROPERTY(o.object_id, 'IsEncrypted') AS is_encrypted"))
        #expect(list.contains("AS definition_withheld"))
        #expect(MSSQLObjectQueries.routineDefinition(schema: "dbo", name: "p")
            .contains("OBJECTPROPERTY(o.object_id, 'IsEncrypted')"))
    }

    /// Selecting every body to draw a list of names pulled a whole schema's source over the wire
    /// and dropped it; the reader's own open re-queries the one they asked for.
    @Test("The listing carries no routine bodies")
    func listingOmitsBodies() {
        let list = MSSQLObjectQueries.routineList(schema: "dbo")
        #expect(!list.contains("m.definition,"))
        #expect(MSSQLObjectQueries.routineDefinition(schema: "dbo", name: "p").contains("m.definition"))
    }

    /// A CLR routine has no sys.sql_modules row at all, so the inner join this replaced returned
    /// zero rows and the caller reported a routine sitting in the list as no longer existing.
    /// Measured against SQL Server 2022 with an object that has no module row: inner join 0 rows,
    /// left join 1 row.
    @Test("The definition query survives a routine with no SQL module row")
    func definitionQueryUsesLeftJoin() {
        let sql = MSSQLObjectQueries.routineDefinition(schema: "dbo", name: "p")
        #expect(sql.contains("FROM sys.objects o"))
        #expect(sql.contains("LEFT JOIN sys.sql_modules m"))
        #expect(!sql.contains("FROM sys.sql_modules"))
        #expect(sql.contains("o.type"))
    }

    @Test("Only T-SQL routines are expected to have a SQL source")
    func sqlSourceIsPerObjectType() {
        for code in ["P ", "FN", "IF", "TF"] {
            #expect(MSSQLObjectQueries.routineHasSQLSource(forObjectType: code))
        }
        for code in ["PC", "FS", "FT", "AF", "X "] {
            #expect(!MSSQLObjectQueries.routineHasSQLSource(forObjectType: code))
        }
    }

    /// Reporting a CLR routine's language as T-SQL is a claim about a body that is not there.
    @Test("Language names the runtime the routine actually runs on")
    func languageFollowsObjectType() {
        #expect(MSSQLObjectQueries.routineLanguage(forObjectType: "P ") == "T-SQL")
        #expect(MSSQLObjectQueries.routineLanguage(forObjectType: "TF") == "T-SQL")
        #expect(MSSQLObjectQueries.routineLanguage(forObjectType: "PC") == "CLR")
        #expect(MSSQLObjectQueries.routineLanguage(forObjectType: "AF") == "CLR")
        #expect(MSSQLObjectQueries.routineLanguage(forObjectType: "X ") == "Extended")
    }
}

struct OracleObjectQueryTests {
    @Test("The trigger list selects the body the old query never asked for")
    func triggerListSelectsBody() {
        let sql = OracleObjectQueries.triggerList(schema: "HR", table: nil)
        #expect(sql.contains("TRIGGER_BODY"))
        #expect(sql.contains("DESCRIPTION"))
        #expect(!sql.contains("TABLE_NAME = "))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let one = OracleObjectQueries.triggerList(schema: "HR", table: "EMPLOYEES")
        #expect(one.contains("TABLE_NAME = 'EMPLOYEES'"))
    }

    private static func trigger(
        name: String = "CS_TRG",
        owner: String? = "PROBE",
        tableOwner: String? = "PROBE",
        description: String?,
        whenClause: String? = nil,
        actionType: String? = "PL/SQL     ",
        status: String? = "ENABLED",
        body: String?
    ) -> OracleTriggerSource {
        OracleTriggerSource(
            name: name, owner: owner, tableOwner: tableOwner, description: description, whenClause: whenClause,
            actionType: actionType, status: status, body: body
        )
    }

    /// The shapes measured on Oracle 23ai: DESCRIPTION ends before the WHEN clause and holds no
    /// DISABLE, so both come from their own columns.
    @Test("A trigger definition writes back its WHEN clause and its disabled state")
    func triggerDefinitionKeepsWhenAndDisable() {
        let definition = OracleObjectQueries.triggerDefinition(Self.trigger(
            description: "trg_b BEFORE INSERT ON t1 FOR EACH ROW FOLLOWS trg_a ",
            whenClause: "NEW.id > 0",
            status: "DISABLED",
            body: "BEGIN :NEW.v := 'b'; END;"
        ))

        #expect(definition == """
            CREATE OR REPLACE TRIGGER trg_b BEFORE INSERT ON t1 FOR EACH ROW FOLLOWS trg_a
            DISABLE
            WHEN (NEW.id > 0)
            BEGIN :NEW.v := 'b'; END;
            """)
    }

    /// TRIGGER_BODY holds only the call's target and a `;` Oracle added. Written back without CALL
    /// the create failed with ORA-04079; with the `;` it is stored INVALID.
    @Test("A CALL trigger is written with CALL and without Oracle's ;")
    func callTriggerDefinition() {
        let definition = OracleObjectQueries.triggerDefinition(Self.trigger(
            description: "trg_call BEFORE INSERT ON t1 FOR EACH ROW\n",
            actionType: "CALL",
            body: "log_it(:NEW.id);"
        ))

        #expect(definition == "CREATE OR REPLACE TRIGGER trg_call BEFORE INSERT ON t1 FOR EACH ROW\nCALL log_it(:NEW.id)")
    }

    @Test("A compound trigger keeps its body and takes its clauses before it")
    func compoundTriggerDefinition() {
        let definition = OracleObjectQueries.triggerDefinition(Self.trigger(
            description: "trg_c FOR INSERT ON t1 ",
            status: "DISABLED",
            body: "COMPOUND TRIGGER\n  BEFORE EACH ROW IS BEGIN NULL; END BEFORE EACH ROW;\nEND trg_c;"
        ))

        #expect(definition.hasPrefix("CREATE OR REPLACE TRIGGER trg_c FOR INSERT ON t1\nDISABLE\nCOMPOUND TRIGGER"))
    }

    /// Written as the source spelled it, a sync into another schema created the trigger back in the
    /// source schema. ALL_SOURCE already gives a procedure without its schema.
    @Test("The owner's schema is taken out of the header, any other schema stays")
    func ownerSchemaIsStripped() {
        let cases: [(header: String, expected: String)] = [
            ("cmp_src.trg_b BEFORE INSERT ON cmp_src.t1 FOR EACH ROW", "trg_b BEFORE INSERT ON t1 FOR EACH ROW"),
            (#""CMP_SRC"."TRG_Q" BEFORE UPDATE OF v ON "CMP_SRC"."T1""#, #""TRG_Q" BEFORE UPDATE OF v ON "T1""#),
            ("trg_logon AFTER LOGON ON cmp_src.SCHEMA", "trg_logon AFTER LOGON ON SCHEMA"),
            ("trg_x BEFORE INSERT ON other.t1 FOR EACH ROW", "trg_x BEFORE INSERT ON other.t1 FOR EACH ROW"),
            (#"trg_y BEFORE INSERT ON "cmp_src".t1"#, #"trg_y BEFORE INSERT ON "cmp_src".t1"#),
            (
                "trg_z BEFORE INSERT ON other.cmp_src REFERENCING NEW AS cmp_src",
                "trg_z BEFORE INSERT ON other.cmp_src REFERENCING NEW AS cmp_src"
            ),
            ("trg_w -- on cmp_src.t1\n  BEFORE DELETE ON CMP_SRC . t1", "trg_w -- on cmp_src.t1\n  BEFORE DELETE ON t1"),
        ]
        for example in cases {
            #expect(OracleObjectQueries.strippingSchema("CMP_SRC", from: example.header) == example.expected, "\(example.header)")
        }
    }

    @Test("A definition read from another schema lands in the schema it runs in")
    func triggerDefinitionDropsTheOwner() {
        let definition = OracleObjectQueries.triggerDefinition(Self.trigger(
            owner: "CMP_SRC",
            tableOwner: "CMP_SRC",
            description: "cmp_src.trg_b BEFORE INSERT ON cmp_src.t1 FOR EACH ROW",
            body: "BEGIN NULL; END;"
        ))

        #expect(definition == "CREATE OR REPLACE TRIGGER trg_b BEFORE INSERT ON t1 FOR EACH ROW\nBEGIN NULL; END;")
    }

    /// Listed with HR's table and replayed from HR, an unqualified header would create HR.TRG and
    /// leave AUDIT.TRG, the trigger that was opened, as it was.
    @Test("A trigger one schema owns on another schema's table keeps its header as written")
    func crossSchemaTriggerKeepsItsQualifiers() {
        let definition = OracleObjectQueries.triggerDefinition(Self.trigger(
            owner: "AUDIT",
            tableOwner: "HR",
            description: "audit.trg BEFORE INSERT ON hr.t FOR EACH ROW",
            body: "BEGIN NULL; END;"
        ))

        #expect(definition == "CREATE OR REPLACE TRIGGER audit.trg BEFORE INSERT ON hr.t FOR EACH ROW\nBEGIN NULL; END;")
    }

    @Test("A missing description still produces a runnable header")
    func triggerDefinitionFallsBackToName() {
        let definition = OracleObjectQueries.triggerDefinition(Self.trigger(
            name: "AUDIT_EMP", description: nil, body: "BEGIN NULL; END;"
        ))
        #expect(definition.hasPrefix("CREATE OR REPLACE TRIGGER \"AUDIT_EMP\""))
    }

    @Test("The trigger list reads ACTION_TYPE, and TRIGGER_BODY stays the last column because it is a LONG")
    func triggerListSelectsActionType() {
        let sql = OracleObjectQueries.triggerList(schema: "HR", table: nil)
        #expect(sql.contains("ACTION_TYPE,\n    TABLE_OWNER,\n    TRIGGER_BODY\nFROM SYS.ALL_TRIGGERS"))
    }

    /// Unqualified, a trigger another schema owns is looked up in the current schema instead.
    @Test("A trigger drop names its schema only when that is not the current one")
    func dropTriggerQualification() {
        #expect(OracleObjectQueries.dropTrigger(name: "T", schema: "HR", currentSchema: "HR") == #"DROP TRIGGER "T""#)
        #expect(OracleObjectQueries.dropTrigger(name: "T", schema: "APP", currentSchema: "HR") == #"DROP TRIGGER "APP"."T""#)
        #expect(OracleObjectQueries.dropTrigger(name: "T", schema: nil, currentSchema: "HR") == #"DROP TRIGGER "T""#)
    }

    @Test("Timing and orientation are read out of the trigger type")
    func timingAndOrientation() {
        #expect(OracleObjectQueries.timing(fromTriggerType: "BEFORE EACH ROW") == "BEFORE")
        #expect(OracleObjectQueries.timing(fromTriggerType: "AFTER STATEMENT") == "AFTER")
        #expect(OracleObjectQueries.timing(fromTriggerType: "INSTEAD OF") == "INSTEAD OF")
        #expect(OracleObjectQueries.orientation(fromTriggerType: "BEFORE EACH ROW") == "ROW")
        #expect(OracleObjectQueries.orientation(fromTriggerType: "AFTER STATEMENT") == "STATEMENT")
    }

    /// A packaged routine is an OBJECT_TYPE of PACKAGE, so listing only PROCEDURE and FUNCTION
    /// keeps it out. It is addressed through its package and has a different DDL call, so a row
    /// for it here would be a row whose source cannot be fetched.
    @Test("Packaged routines stay out of the standalone list")
    func packagedRoutinesExcluded() {
        let sql = OracleObjectQueries.routineList(schema: "HR")
        #expect(sql.contains("OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION')"))
        #expect(sql.contains("ALL_OBJECTS"))
    }

    /// LISTAGG caps at 4000 bytes and raises ORA-01489 past it, which fails the whole SELECT and
    /// loses every routine in the schema over one wide signature. Oracle only overloads inside a
    /// package, so a standalone routine needs no argument list to be identified.
    @Test("The routine list builds no argument signature")
    func routineListAvoidsListagg() {
        let sql = OracleObjectQueries.routineList(schema: "HR")
        #expect(!sql.contains("LISTAGG"))
        #expect(!sql.contains("ALL_ARGUMENTS"))
    }

    /// A schema browse asks for the triggers this schema owns; a per-table fetch asks for the
    /// triggers on that table. The two columns differ for a cross-schema trigger.
    @Test("Schema scope reads OWNER and table scope reads TABLE_OWNER")
    func triggerScopeColumns() {
        let schemaWide = OracleObjectQueries.triggerList(schema: "HR", table: nil)
        #expect(schemaWide.contains("WHERE OWNER = 'HR'"))
        #expect(!schemaWide.contains("TABLE_OWNER = 'HR'"))

        let perTable = OracleObjectQueries.triggerList(schema: "HR", table: "EMPLOYEES")
        #expect(perTable.contains("TABLE_OWNER = 'HR'"))
        #expect(perTable.contains("TABLE_NAME = 'EMPLOYEES'"))
    }

    @Test("ALL_SOURCE is read in line order")
    func routineSourceOrdersByLine() {
        let sql = OracleObjectQueries.routineSource(schema: "HR", name: "P", type: "PROCEDURE")
        #expect(sql.contains("ORDER BY LINE"))
        #expect(sql.contains("ALL_SOURCE"))
    }

    @Test("A quote in a schema or name is escaped")
    func literalsAreEscaped() {
        #expect(OracleObjectQueries.routineList(schema: "IT'S").contains("'IT''S'"))
        #expect(
            OracleObjectQueries.routineSource(schema: "HR", name: "X'; DROP", type: "PROCEDURE")
                .contains("'X''; DROP'")
        )
    }
}
