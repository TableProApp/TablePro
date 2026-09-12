//
//  PostgreSQLLegacyCatalogQueryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQL catalog reads that PostgreSQL 9.1 accepts")
struct PostgreSQLLegacyCatalogQueryTests {
    private static let constructsMissingBefore96 = [
        "to_regclass", "LATERAL", "WITH ORDINALITY", "json", "array_remove", "array_position", "FILTER (",
        "unnest("
    ]

    static let legacy = PostgreSQLCapabilities(serverVersion: 90_124)

    private static func unavailableConstructs(in sql: String) -> [String] {
        constructsMissingBefore96.filter { sql.contains($0) }
    }

    @Test("Every rewritten read stays inside what PostgreSQL 9.1 parses")
    func rewrittenReadsArePortable() {
        let legacy = Self.legacy
        let queries = [
            PostgreSQLForeignKeyQueries.foreignKeyList(schema: "public", table: "orders", capabilities: legacy),
            PostgreSQLForeignKeyQueries.foreignKeyList(schema: "public", table: nil, capabilities: legacy),
            PostgreSQLIndexQueries.indexList(schema: "public", table: "orders"),
            PostgreSQLIndexQueries.indexList(schema: "public", table: nil),
            PostgreSQLObjectQueries.triggerList(schema: "public", table: nil),
            PostgreSQLObjectQueries.userDefinedTypeList(schema: "public", identity: nil, capabilities: legacy),
            PostgreSQLSchemaQueries.checkConstraintsQuery(schema: "public", table: "t"),
            PostgreSQLSchemaQueries.collationList(capabilities: legacy),
            PostgreSQLSchemaQueries.allTablesMetadata(schema: "public"),
            PostgreSQLPrincipalQueries.databaseGrants(role: "r"),
            PostgreSQLPrincipalQueries.schemaGrants(role: "r"),
            PostgreSQLPrincipalQueries.tableGrants(role: "r"),
            PostgreSQLPrincipalQueries.columnGrants(role: "r"),
            PostgreSQLSequenceQueries.sequenceList(schema: "public", dependentOnTable: "orders", source: .sequenceParameters),
            PostgreSQLSchemaQueries.fetchTables(schema: "public", includeMaterializedViews: true, includeForeignTables: true),
            PostgreSQLViewDefinition.catalogQuery(name: "v", schema: "public")
        ]
        for sql in queries {
            #expect(Self.unavailableConstructs(in: sql).isEmpty, "\(sql)")
        }
    }

    @Test("Every name reaching these reads is quoted so standard_conforming_strings cannot change it")
    func namesAreQuotedInEveryRead() {
        let hostile = "a\\b'c"
        let queries = [
            PostgreSQLObjectQueries.triggerList(schema: hostile, table: hostile),
            PostgreSQLObjectQueries.routineList(schema: hostile, capabilities: Self.legacy),
            PostgreSQLSchemaQueries.checkConstraintsQuery(schema: hostile, table: hostile),
            PostgreSQLSchemaQueries.fetchTables(
                schema: hostile, includeMaterializedViews: true, includeForeignTables: true
            )
        ]
        for sql in queries {
            #expect(sql.contains("E'a\\\\b''c'"), "\(sql)")
            #expect(!sql.contains("'a\\b'c'"))
        }
    }

    @Test("The search-path fallback parenthesises the function before subscripting it")
    func searchPathFallbackParses() {
        #expect(PostgreSQLSchemaQueries.firstSearchPathSchema == "SELECT (current_schemas(false))[1]")
    }
}

@Suite("PostgreSQL foreign key catalog read")
struct PostgreSQLForeignKeyQueryTests {
    private static let modern = PostgreSQLCapabilities(serverVersion: 170_011)
    private static let beforeConstraintParent = PostgreSQLCapabilities(serverVersion: 100_021)

    @Test("Schema and table predicates sit inside the derived table, before the key positions expand")
    func predicatesAreInsideTheDerivedTable() throws {
        let sql = PostgreSQLForeignKeyQueries.foreignKeyList(schema: "public", table: "orders", capabilities: Self.modern)
        let derivedEnd = try #require(sql.range(of: ") con"))
        let inside = sql[..<derivedEnd.lowerBound]
        #expect(inside.contains("ns.nspname = 'public'"))
        #expect(inside.contains("src.relname = 'orders'"))
        #expect(inside.contains("pg_catalog.generate_subscripts(c.conkey, 1) AS ord"))
    }

    @Test("Column pairs are matched by key position, so a reversed composite key keeps its pairing")
    func pairsByKeyPosition() {
        let sql = PostgreSQLForeignKeyQueries.foreignKeyList(schema: "public", table: nil, capabilities: Self.modern)
        #expect(sql.contains("src_col.attnum = con.conkey[con.ord]"))
        #expect(sql.contains("ref_col.attnum = con.confkey[con.ord]"))
        #expect(sql.contains("ORDER BY src_cl.relname, con.conname, con.ord"))
    }

    @Test("The whole-schema read has no table predicate and the same projection")
    func bulkFormSharesProjection() {
        let bulk = PostgreSQLForeignKeyQueries.foreignKeyList(schema: "public", table: nil, capabilities: Self.modern)
        let single = PostgreSQLForeignKeyQueries.foreignKeyList(schema: "public", table: "orders", capabilities: Self.modern)
        #expect(!bulk.contains("src.relname ="))
        let projection: (String) -> Substring = { $0[..<($0.range(of: "FROM (")?.lowerBound ?? $0.endIndex)] }
        #expect(projection(bulk) == projection(single))
    }

    @Test("A constraint cloned onto a partition of the referenced table is left out")
    func partitionClonesAreExcluded() {
        let sql = PostgreSQLForeignKeyQueries.foreignKeyList(
            schema: "public", table: nil, capabilities: Self.modern
        )
        #expect(sql.contains("parent.oid = c.conparentid"))
        #expect(sql.contains("parent.conrelid = c.conrelid"))
    }

    @Test("Servers without conparentid keep the unfiltered read, since the column fails at parse time")
    func cloneFilterNeedsConstraintParent() {
        let sql = PostgreSQLForeignKeyQueries.foreignKeyList(
            schema: "public", table: nil, capabilities: Self.beforeConstraintParent
        )
        #expect(!sql.contains("conparentid"))
    }

    @Test("A server that reports no version still gets the clone filter and the modern collation read")
    func unknownVersionIsTreatedAsModern() {
        let unknown = PostgreSQLCapabilities.assumingModernWhenUnknown(0)
        let sql = PostgreSQLForeignKeyQueries.foreignKeyList(schema: "public", table: nil, capabilities: unknown)
        #expect(sql.contains("parent.oid = c.conparentid"))
        #expect(PostgreSQLSchemaQueries.collationList(capabilities: unknown).contains("collprovider"))
    }

    @Test("Names are quoted as literals that survive either standard_conforming_strings setting")
    func namesAreQuoted() {
        let sql = PostgreSQLForeignKeyQueries.foreignKeyList(schema: "o'brien", table: "a\\b", capabilities: Self.modern)
        #expect(sql.contains("ns.nspname = 'o''brien'"))
        #expect(sql.contains("src.relname = E'a\\\\b'"))
    }

    @Test("One decoder reads both forms, table first")
    func decoderReadsTableFirst() throws {
        let row: [PluginCellValue] = [
            .text("fk_child"), .text("fk_rev"), .text("y"), .text("fk_parent"), .text("b"),
            .text("public"), .text("NO ACTION"), .text("CASCADE")
        ]
        let decoded = try #require(PostgreSQLForeignKeyRow(row))
        #expect(decoded.table == "fk_child")
        #expect(decoded.foreignKey.name == "fk_rev")
        #expect(decoded.foreignKey.column == "y")
        #expect(decoded.foreignKey.referencedTable == "fk_parent")
        #expect(decoded.foreignKey.referencedColumn == "b")
        #expect(decoded.foreignKey.referencedSchema == "public")
        #expect(decoded.foreignKey.onDelete == "NO ACTION")
        #expect(decoded.foreignKey.onUpdate == "CASCADE")
    }

    @Test("A row missing its referential actions is rejected rather than read shifted")
    func shortRowIsRejected() {
        let row: [PluginCellValue] = [.text("orders"), .text("fk"), .text("a"), .text("b"), .text("c"), .text("public"), .text("NO ACTION")]
        #expect(PostgreSQLForeignKeyRow(row) == nil)
    }
}

@Suite("PostgreSQL index catalog read")
struct PostgreSQLIndexQueryTests {
    @Test("Key order comes from the key position, found without array_position")
    func keyOrderWithoutArrayPosition() {
        let sql = PostgreSQLIndexQueries.indexList(schema: "public", table: nil)
        #expect(sql.contains("FROM pg_catalog.generate_subscripts(ix.indkey, 1) AS k"))
        #expect(sql.contains("WHERE ix.indkey[k] = a.attnum"))
        #expect(sql.contains("a.attnum = ANY(ix.indkey)"))
    }

    @Test("The per-table read adds one predicate to the whole-schema read")
    func perTableAddsOnePredicate() {
        let single = PostgreSQLIndexQueries.indexList(schema: "public", table: "orders")
        let bulk = PostgreSQLIndexQueries.indexList(schema: "public", table: nil)
        #expect(single.contains("AND t.relname = 'orders'"))
        #expect(!bulk.contains("t.relname ="))
    }

    @Test("A column name holding a comma or a space stays one column")
    func quotedColumnNamesStayWhole() throws {
        let row: [PluginCellValue] = [
            .text("idx_t"), .text("idx_weird"), .text(#"{"d,e",b,"first name"}"#), .text("false"), .text("false"),
            .text("btree"), .null
        ]
        let decoded = try #require(PostgreSQLIndexRow.index(from: row))
        #expect(decoded.table == "idx_t")
        #expect(decoded.index.columns == ["d,e", "b", "first name"])
        #expect(decoded.index.type == "BTREE")
        #expect(!decoded.index.isUnique)
    }

    @Test("A unique partial index keeps its flags and predicate")
    func flagsAndPredicate() throws {
        let row: [PluginCellValue] = [
            .text("orders"), .text("orders_big_amount"), .text("{amount}"), .text("true"), .text("false"),
            .text("btree"), .text("(amount > (100)::numeric)")
        ]
        let decoded = try #require(PostgreSQLIndexRow.index(from: row))
        #expect(decoded.index.columns == ["amount"])
        #expect(decoded.index.isUnique)
        #expect(!decoded.index.isPrimary)
        #expect(decoded.index.whereClause == "(amount > (100)::numeric)")
    }
}

@Suite("PostgreSQL check constraint columns")
struct PostgreSQLCheckConstraintColumnTests {
    @Test("Column names come back whole from the array literal the server prints")
    func hostileNames() {
        let columns = PostgreSQLTextArray.values( #"{"a b","c,d","q\"t","x{y}"}"#)
        #expect(columns == ["a b", "c,d", "q\"t", "x{y}"])
    }

    @Test("A constraint that names no column reads as an empty list")
    func noColumns() {
        #expect(PostgreSQLTextArray.values( "{}").isEmpty)
        #expect(PostgreSQLTextArray.values( nil).isEmpty)
    }

    @Test("The query aggregates names with array_agg and defaults to an empty array")
    func queryShape() {
        let sql = PostgreSQLSchemaQueries.checkConstraintsQuery(schema: "public", table: "t")
        #expect(sql.contains("array_agg(att.attname ORDER BY att.attnum)::text"))
        #expect(sql.contains("att.attnum = ANY (con.conkey)"))
        #expect(sql.contains("'{}'"))
    }
}

@Suite("PostgreSQL sequence reads")
struct PostgreSQLSequenceQueryTests {
    @Test("pg_sequences is read wherever it exists, and every other server reads the sequences one by one")
    func sourceSelection() {
        #expect(PostgreSQLSequenceQueries.source(hasSequencesCatalog: true) == .sequencesView)
        #expect(PostgreSQLSequenceQueries.source(hasSequencesCatalog: false) == .sequenceParameters)
    }

    @Test("pg_sequences arrived in PostgreSQL 10, not 9.5")
    func sequencesCatalogThreshold() {
        #expect(!PostgreSQLCapabilities(serverVersion: 90_500).hasSequencesCatalog)
        #expect(!PostgreSQLCapabilities(serverVersion: 90_624).hasSequencesCatalog)
        #expect(PostgreSQLCapabilities(serverVersion: 100_000).hasSequencesCatalog)
    }

    @Test("A sequence the role cannot read reports no parameters instead of failing the listing")
    func legacyListingIsPrivilegeGuarded() {
        let sql = PostgreSQLSequenceQueries.sequenceList(schema: "public", dependentOnTable: nil, source: .sequenceParameters)
        #expect(sql.contains("pg_catalog.has_sequence_privilege(c.oid, 'SELECT,USAGE,UPDATE') AS can_read_parameters"))
        #expect(sql.contains("(pg_catalog.pg_sequence_parameters(s.oid)).start_value"))
        #expect(sql.contains("pg_catalog.has_sequence_privilege(c.oid, 'SELECT') AS readable"))
        #expect(!sql.contains("pg_sequences"))
    }

    @Test("A table's sequences are the ones its column defaults depend on, in either source")
    func dependencyComesFromPgDepend() {
        for source in [PostgreSQLSequenceQueries.Source.sequencesView, .sequenceParameters] {
            let sql = PostgreSQLSequenceQueries.sequenceList(schema: "public", dependentOnTable: "orders", source: source)
            #expect(sql.contains("d.classid = 'pg_catalog.pg_attrdef'::pg_catalog.regclass"))
            #expect(sql.contains("d.refobjid = c.oid"))
            #expect(sql.contains("t.relname = 'orders'"))
            #expect(!sql.contains("LIKE"))
        }
    }

    @Test("Each sequence's last value is its own statement, qualified and quoted")
    func lastValueIsPerSequence() {
        let sql = PostgreSQLSequenceQueries.lastValue(schema: "app", sequence: "we\"ird's")
        #expect(sql == "SELECT CASE WHEN is_called THEN last_value END FROM \"app\".\"we\"\"ird's\"")
        #expect(!sql.contains("UNION ALL"))
    }

    @Test("A server that reports 10 but carries no pg_sequences still lists its sequences")
    func missingCatalogFallsBackToParameters() {
        #expect(PostgreSQLSequenceQueries.source(hasSequencesCatalog: false) == .sequenceParameters)
        #expect(PostgreSQLSequenceQueries.source(hasSequencesCatalog: true) == .sequencesView)
    }

    @Test("The pre-10 listing tests each sequence's privileges once, in a derived table the planner cannot flatten")
    func privilegesReadOncePerSequence() {
        let sql = PostgreSQLSequenceQueries.sequenceList(
            schema: "public", dependentOnTable: nil, source: .sequenceParameters
        )
        #expect(sql.components(separatedBy: "has_sequence_privilege").count - 1 == 2)
        #expect(sql.contains("OFFSET 0"))
        #expect(sql.contains("CASE WHEN s.can_read_parameters"))
        #expect(!sql.contains("AS parameters"))
    }

    @Test("Rows decode with booleans in any of the server's spellings")
    func definitionsDecode() {
        let rows: [[PluginCellValue]] = [
            [.text("we,ird_seq"), .text("7"), .text("5"), .text("50"), .text("1"), .text("t"), .null, .text("true")],
            [.text("hidden"), .null, .null, .null, .null, .null, .null, .text("f")]
        ]
        let definitions = PostgreSQLSequenceQueries.definitions(from: rows)
        #expect(definitions.count == 2)
        #expect(definitions[0].cycles)
        #expect(definitions[0].needsLastValueRead)
        #expect(!definitions[1].cycles)
        #expect(!definitions[1].needsLastValueRead)
    }

    @Test("A sequence with known parameters restores with them and its position")
    func fullDefinition() {
        let definition = PostgreSQLSequenceDefinition(
            name: "invoice_seq", startValue: "1000", minValue: "1", maxValue: "9223372036854775807",
            increment: "5", cycles: false, lastValue: "1005", needsLastValueRead: false
        )
        #expect(definition.ddl == """
            CREATE SEQUENCE "invoice_seq" INCREMENT BY 5 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1000;
            SELECT pg_catalog.setval('"invoice_seq"', 1005, true);
            """)
    }

    @Test("A sequence whose parameters the role could not read is still created, with defaults")
    func unknownParameters() {
        let definition = PostgreSQLSequenceDefinition(
            name: "hidden", startValue: nil, minValue: nil, maxValue: nil, increment: nil,
            cycles: false, lastValue: nil, needsLastValueRead: false
        )
        #expect(definition.ddl == "CREATE SEQUENCE \"hidden\";")
    }

    @Test("The setval target is an identifier inside a literal, so a quote in the name cannot break either")
    func hostileNameInSetval() {
        let definition = PostgreSQLSequenceDefinition(
            name: "we\"ird's", startValue: "7", minValue: "5", maxValue: "50", increment: "1",
            cycles: true, lastValue: "8", needsLastValueRead: false
        )
        #expect(definition.ddl.hasPrefix("CREATE SEQUENCE \"we\"\"ird's\" INCREMENT BY 1 MINVALUE 5 MAXVALUE 50 START WITH 7 CYCLE;"))
        #expect(definition.ddl.hasSuffix("SELECT pg_catalog.setval('\"we\"\"ird''s\"', 8, true);"))
    }

    @Test("A last value that is not a number is left out rather than interpolated")
    func nonNumericLastValue() {
        let definition = PostgreSQLSequenceDefinition(
            name: "s", startValue: "1", minValue: "1", maxValue: "10", increment: "1",
            cycles: false, lastValue: "1); DROP TABLE t; --", needsLastValueRead: false
        )
        #expect(!definition.ddl.contains("setval"))
    }

    @Test("Reading a last value clears the pending read")
    func withLastValue() {
        let definition = PostgreSQLSequenceDefinition(
            name: "s", startValue: "1", minValue: "1", maxValue: "10", increment: "1",
            cycles: false, lastValue: nil, needsLastValueRead: true
        )
        let read = definition.withLastValue("4")
        #expect(read.lastValue == "4")
        #expect(!read.needsLastValueRead)
    }
}

@Suite("PostgreSQL collation and table metadata reads")
struct PostgreSQLCollationAndMetadataQueryTests {
    @Test("Before PostgreSQL 10 every collation but the default is a libc one")
    func legacyCollations() {
        let sql = PostgreSQLSchemaQueries.collationList(capabilities: PostgreSQLCapabilities(serverVersion: 90_624))
        #expect(!sql.contains("collprovider"))
        #expect(sql.contains("WHERE oid <> 100"))
        let modern = PostgreSQLSchemaQueries.collationList(capabilities: PostgreSQLCapabilities(serverVersion: 170_000))
        #expect(modern.contains("collprovider IN ('b', 'c', 'i')"))
    }

    @Test("Table sizes and comments are read by relation oid, so a mixed-case name resolves")
    func allTablesMetadataUsesRelid() {
        let sql = PostgreSQLSchemaQueries.allTablesMetadata(schema: "app")
        #expect(sql.contains("pg_total_relation_size(relid)"))
        #expect(sql.contains("obj_description(relid, 'pg_class')"))
        #expect(!sql.contains("::regclass"))
        #expect(!sql.contains("||'.'||"))
    }

    @Test("The schema is quoted as a literal")
    func allTablesMetadataQuotesSchema() {
        #expect(PostgreSQLSchemaQueries.allTablesMetadata(schema: "o'brien").contains("schemaname = 'o''brien'"))
        #expect(PostgreSQLSchemaQueries.allTablesMetadata(schema: "a\\b").contains("schemaname = E'a\\\\b'"))
    }
}

@Suite("PostgreSQL grant reads")
struct PostgreSQLGrantQueryTests {
    @Test("aclexplode runs in a subquery's select list, which PostgreSQL 9.1 accepts")
    func grantsAvoidLateral() {
        let queries = [
            PostgreSQLPrincipalQueries.databaseGrants(role: "reader"),
            PostgreSQLPrincipalQueries.schemaGrants(role: "reader"),
            PostgreSQLPrincipalQueries.tableGrants(role: "reader"),
            PostgreSQLPrincipalQueries.columnGrants(role: "reader")
        ]
        for sql in queries {
            #expect(!sql.contains("LATERAL"))
            #expect(sql.contains("pg_catalog.aclexplode("))
            #expect(sql.contains("JOIN pg_roles r ON r.oid = (s.acl).grantee"))
            #expect(sql.contains("r.rolname = 'reader'"))
        }
    }
}

@Suite("PostgreSQL catalog booleans")
struct PostgreSQLCatalogBooleanTests {
    @Test("The driver hands a boolean column over as true or false, and a text cast may say t or f")
    func spellings() {
        #expect(PostgreSQLCatalogBoolean.isTrue("true"))
        #expect(PostgreSQLCatalogBoolean.isTrue("t"))
        #expect(PostgreSQLCatalogBoolean.isTrue("TRUE"))
        #expect(PostgreSQLCatalogBoolean.isTrue("YES"))
        #expect(PostgreSQLCatalogBoolean.isTrue("on"))
        #expect(PostgreSQLCatalogBoolean.isTrue("1"))
        #expect(!PostgreSQLCatalogBoolean.isTrue("false"))
        #expect(!PostgreSQLCatalogBoolean.isTrue("f"))
        #expect(!PostgreSQLCatalogBoolean.isTrue("no"))
        #expect(!PostgreSQLCatalogBoolean.isTrue("off"))
        #expect(!PostgreSQLCatalogBoolean.isTrue("0"))
        #expect(!PostgreSQLCatalogBoolean.isTrue(""))
        #expect(!PostgreSQLCatalogBoolean.isTrue(nil))
    }

    @Test("A primary key index decoded from the driver's boolean text is unique and primary")
    func primaryKeyIndexKeepsItsFlags() throws {
        let row: [PluginCellValue] = [
            .text("orders"), .text("orders_pkey"), .text("{id}"), .text("true"), .text("true"), .text("btree"), .null
        ]
        let decoded = try #require(PostgreSQLIndexRow.index(from: row))
        #expect(decoded.index.isUnique)
        #expect(decoded.index.isPrimary)
    }
}
