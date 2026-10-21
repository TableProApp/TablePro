import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLSequenceListingTests {
    private func listing(sequences: Bool, scope: PostgreSQLTableListingScope = .schema("public")) -> String {
        PostgreSQLTableListing.query(
            in: scope,
            includeMaterializedViews: true,
            includeForeignTables: true,
            includeSequences: sequences
        )
    }

    @Test("The first macOS rung lists sequences; the second and the information_schema rung do not")
    func onlyTheFirstRungListsSequences() {
        #expect(PostgreSQLTableListingLadder.degradableAttempts.first?.includeSequences == true)
        #expect(PostgreSQLTableListingLadder.degradableAttempts.dropFirst().allSatisfy { !$0.includeSequences })
        #expect(!PostgreSQLTableListingLadder.leastCapableAttempt.includeSequences)
    }

    @Test("A sequence is relkind S, labelled SEQUENCE, with its owning column read from pg_depend")
    func sequenceListing() {
        let sql = listing(sequences: true)
        #expect(sql.contains("rc.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')"))
        #expect(sql.contains("WHEN 'S' THEN 'SEQUENCE'"))
        #expect(sql.contains("AS owned_by_table"))
        #expect(sql.contains("AS owned_by_column"))
        #expect(sql.contains("d.deptype IN ('a', 'i')"))
        #expect(sql.contains("d.refobjsubid > 0"))
    }

    @Test("has_sequence_privilege runs only on a sequence, since it raises on any other relation")
    func sequencePrivilegeIsGuardedByRelkind() {
        let sql = listing(sequences: true)
        #expect(sql.contains("CASE WHEN c.relkind = 'S'"))
        #expect(sql.contains("pg_catalog.has_sequence_privilege(c.oid, 'SELECT, UPDATE, USAGE')"))
    }

    @Test("Without the flag the listing is the one iOS and the older rungs run")
    func noSequencesWithoutTheFlag() {
        let sql = listing(sequences: false)
        #expect(!sql.contains("'S'"))
        #expect(!sql.contains("owned_by_table"))
        #expect(!sql.contains("has_sequence_privilege"))
    }

    @Test("The owner columns sit before the schema, so a row is read by its layout")
    func ownerColumnsPrecedeTheSchema() throws {
        let sql = listing(sequences: true, scope: .schemas(["public"]))
        let owner = try #require(sql.range(of: "AS owned_by_column"))
        let schema = try #require(sql.range(of: "AS schema_name"))
        #expect(owner.lowerBound < schema.lowerBound)
    }

    @Test("A sequence row carries its owner and its schema")
    func sequenceRowParses() throws {
        let row: [String?] = ["orders_id_seq", "SEQUENCE", nil, nil, "orders", "id", "sales"]
        let table = try #require(PostgreSQLTableListing.table(fromRow: row, includesSequences: true))
        #expect(table.type == "SEQUENCE")
        #expect(table.ownedByTable == "orders")
        #expect(table.ownedByColumn == "id")
        #expect(table.schema == "sales")
    }

    @Test("A row from a listing without sequences reads the schema where it always was")
    func plainRowParses() throws {
        let row: [String?] = ["orders", "BASE TABLE", "note", "3", "sales"]
        let table = try #require(PostgreSQLTableListing.table(fromRow: row, includesSequences: false))
        #expect(table.type == "TABLE")
        #expect(table.schema == "sales")
        #expect(table.ownedByTable == nil)
        #expect(table.partitionCount == 3)
    }
}

struct PostgreSQLSequenceStatementTests {
    private func sequence(
        name: String = "orders_id_seq",
        schema: String = "public",
        increment: Int64 = 1,
        start: Int64 = 1,
        owner: (String, String)? = ("orders", "id")
    ) -> PluginSequenceDetails {
        PluginSequenceDetails(
            name: name, schema: schema, dataType: "integer", startValue: start, increment: increment,
            minValue: increment < 0 ? -2_147_483_648 : 1, maxValue: increment < 0 ? -1 : 2_147_483_647,
            cacheSize: 1, cycles: false, lastValue: 3, nextValue: 4, ownedByTable: owner?.0, ownedByColumn: owner?.1
        )
    }

    @Test("A typed value is the next one nextval returns")
    func explicitValue() {
        let sql = PostgreSQLSequenceStatements.nextValue(sequence(), schema: "public", nextValue: .value(42))
        #expect(sql == "SELECT pg_catalog.setval('\"public\".\"orders_id_seq\"', 42, false)")
    }

    @Test("After the owning column: past the column's highest value, never behind the sequence, writers held off")
    func afterOwnedColumnAscending() {
        let sql = PostgreSQLSequenceStatements.nextValue(sequence(), schema: "public", nextValue: .afterOwnedColumn)
        #expect(sql == """
            SET LOCAL row_security = off;
            LOCK TABLE "public"."orders" IN SHARE ROW EXCLUSIVE MODE;
            SELECT pg_catalog.setval('"public"."orders_id_seq"', \
            GREATEST(COALESCE(pg_catalog.max("id")::bigint + 1, 1), \
            (SELECT CASE WHEN is_called THEN last_value + 1 ELSE last_value END FROM "public"."orders_id_seq")), \
            false) FROM "public"."orders"
            """)
    }

    @Test("A server without row security gets no row_security setting")
    func noRowSecurityBefore95() {
        let sql = PostgreSQLSequenceStatements.nextValue(
            sequence(), schema: "public", nextValue: .afterOwnedColumn, hasRowSecurity: false
        )
        #expect(sql?.hasPrefix("LOCK TABLE") == true)
    }

    @Test("A descending sequence continues below the column's lowest value")
    func afterOwnedColumnDescending() {
        let sql = PostgreSQLSequenceStatements.nextValue(
            sequence(increment: -2, start: -1), schema: "public", nextValue: .afterOwnedColumn
        )
        #expect(sql?.contains("LEAST(COALESCE(pg_catalog.min(\"id\")::bigint + -2, -1), ") == true)
        #expect(sql?.contains("THEN last_value + -2 ELSE last_value END") == true)
    }

    @Test("A sequence no column owns has no column to continue from")
    func afterOwnedColumnWithoutOwner() {
        let sql = PostgreSQLSequenceStatements.nextValue(
            sequence(owner: nil), schema: "public", nextValue: .afterOwnedColumn
        )
        #expect(sql == nil)
    }

    @Test("Names are quoted as identifiers, and the target as a literal around them")
    func hostileNames() {
        let sql = PostgreSQLSequenceStatements.nextValue(
            sequence(name: "we\"ird's", schema: "it's", owner: ("t'b", "c\"l")),
            schema: "it's",
            nextValue: .afterOwnedColumn
        )
        #expect(sql?.contains("SELECT pg_catalog.setval('\"it''s\".\"we\"\"ird''s\"', ") == true)
        #expect(sql?.contains("LOCK TABLE \"it's\".\"t'b\" IN SHARE ROW EXCLUSIVE MODE;") == true)
        #expect(sql?.contains("FROM \"it's\".\"we\"\"ird's\")") == true)
        #expect(sql?.contains("pg_catalog.max(\"c\"\"l\")") == true)
        #expect(sql?.hasSuffix("FROM \"it's\".\"t'b\"") == true)
    }

    @Test("ALTER SEQUENCE names only what changed")
    func alterNamesOnlyChanges() throws {
        let current = sequence()
        var settings = try #require(current.settings)
        settings.increment = 5
        settings.cycles = true
        #expect(PostgreSQLSequenceStatements.alter(current, schema: "public", settings: settings)
            == "ALTER SEQUENCE \"public\".\"orders_id_seq\" INCREMENT BY 5 CYCLE")
    }

    @Test("Every setting can change at once")
    func alterEverySetting() {
        let current = sequence()
        let settings = PluginSequenceSettings(increment: 2, minValue: 0, maxValue: 100, cacheSize: 20, cycles: true)
        #expect(PostgreSQLSequenceStatements.alter(current, schema: "public", settings: settings)
            == "ALTER SEQUENCE \"public\".\"orders_id_seq\" INCREMENT BY 2 MINVALUE 0 MAXVALUE 100 CACHE 20 CYCLE")
    }

    @Test("Nothing changed is no statement")
    func alterWithoutChanges() throws {
        let current = sequence()
        let settings = try #require(current.settings)
        #expect(PostgreSQLSequenceStatements.alter(current, schema: "public", settings: settings) == nil)
    }

    @Test("Turning cycling off says so")
    func alterNoCycle() throws {
        let current = PluginSequenceDetails(
            name: "s", schema: "public", dataType: "bigint", startValue: 1, increment: 1, minValue: 1,
            maxValue: 10, cacheSize: 1, cycles: true, lastValue: nil, nextValue: nil, ownedByTable: nil, ownedByColumn: nil
        )
        var settings = try #require(current.settings)
        settings.cycles = false
        #expect(PostgreSQLSequenceStatements.alter(current, schema: "public", settings: settings)
            == "ALTER SEQUENCE \"public\".\"s\" NO CYCLE")
    }
}

struct PostgreSQLSequenceDefinitionDDLTests {
    private func definition(
        dataType: String? = "integer",
        cacheSize: String? = "1",
        owner: (String, String, String)? = ("orders", "id", "a"),
        lastValue: String? = "50"
    ) -> PostgreSQLSequenceDefinition {
        var definition = PostgreSQLSequenceDefinition(
            name: "orders_id_seq", startValue: "1", minValue: "1", maxValue: "2147483647",
            increment: "1", cycles: false, lastValue: lastValue, needsLastValueRead: false
        )
        definition.dataType = dataType
        definition.cacheSize = cacheSize
        definition.ownedByTable = owner?.0
        definition.ownedByColumn = owner?.1
        definition.ownerDependency = owner?.2
        return definition
    }

    @Test("A serial's sequence keeps its integer type, so a restore does not widen it to bigint")
    func integerTypeIsWritten() {
        #expect(definition().ddl.hasPrefix("CREATE SEQUENCE \"orders_id_seq\" AS integer INCREMENT BY 1"))
    }

    @Test("bigint is the default and is not written")
    func bigintIsNotWritten() {
        #expect(!definition(dataType: "bigint").ddl.contains(" AS "))
    }

    @Test("A cache other than 1 is kept")
    func cacheIsWritten() {
        #expect(definition(cacheSize: "20").ddl.contains("START WITH 1 CACHE 20;"))
        #expect(!definition(cacheSize: "1").ddl.contains("CACHE"))
    }

    @Test("A type the catalog should never report is not interpolated")
    func unknownTypeIsDropped() {
        #expect(!definition(dataType: "integer; DROP TABLE t").ddl.contains("DROP"))
    }

    @Test("The export form stays relative and leaves the owner to the table it belongs to")
    func exportFormIsRelative() {
        let ddl = definition().ddl
        #expect(!ddl.contains("\"public\"."))
        #expect(!ddl.contains("OWNED BY"))
    }

    @Test("The sequence's own DDL is qualified, names its owning column and its position")
    func qualifiedDDL() {
        #expect(definition().qualifiedDDL(schema: "public") == """
            CREATE SEQUENCE "public"."orders_id_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1;
            ALTER SEQUENCE "public"."orders_id_seq" OWNED BY "public"."orders"."id";
            SELECT pg_catalog.setval('"public"."orders_id_seq"', 50, true);
            """)
    }

    @Test("An identity column's sequence belongs to its column, so no OWNED BY is written")
    func identitySequenceHasNoOwnedBy() {
        let ddl = definition(owner: ("items", "id", "i")).qualifiedDDL(schema: "public")
        #expect(!ddl.contains("OWNED BY"))
    }

    @Test("The details carry every setting as a number and the owner")
    func detailsMapping() {
        let details = definition(cacheSize: "20").details(schema: "public")
        #expect(details.dataType == "integer")
        #expect(details.increment == 1)
        #expect(details.maxValue == 2_147_483_647)
        #expect(details.cacheSize == 20)
        #expect(details.lastValue == 50)
        #expect(details.ownedByTable == "orders")
        #expect(details.ownedByColumn == "id")
        #expect(details.settings == PluginSequenceSettings(
            increment: 1, minValue: 1, maxValue: 2_147_483_647, cacheSize: 20, cycles: false
        ))
    }

    @Test("A setting the role could not read leaves no settings to edit")
    func unreadableSettings() {
        #expect(definition(cacheSize: nil).details(schema: "public").settings == nil)
    }

    @Test("The extended listing columns decode by position")
    func rowsDecodeTheNewColumns() throws {
        let rows: [[PluginCellValue]] = [[
            .text("orders_id_seq"), .text("1"), .text("1"), .text("2147483647"), .text("1"), .text("f"),
            .text("50"), .text("f"), .text("integer"), .text("1"), .text("orders"), .text("id"), .text("a")
        ]]
        let decoded = try #require(PostgreSQLSequenceQueries.definitions(from: rows).first)
        #expect(decoded.dataType == "integer")
        #expect(decoded.cacheSize == "1")
        #expect(decoded.ownedByTable == "orders")
        #expect(decoded.ownedByColumn == "id")
        #expect(decoded.ownerDependency == "a")
    }

    @Test("One sequence is read by name in either source")
    func namedRead() {
        for source in [PostgreSQLSequenceQueries.Source.sequencesView, .sequenceParameters] {
            let sql = PostgreSQLSequenceQueries.sequenceList(
                schema: "public", dependentOnTable: nil, source: source, named: "it's"
            )
            #expect(sql.contains("= 'it''s'"))
            #expect(sql.contains("AS owner_dependency"))
        }
    }
}

struct PostgreSQLSequencePositionTests {
    @Test("After setval(..., false) the next value is the value set, not the start")
    func notCalledIsTheValueItself() {
        let position = PostgreSQLSequencePosition(lastValue: 100, isCalled: false)
        #expect(position.nextValue(increment: 1, minValue: 1, maxValue: 1_000, cycles: false) == 100)
    }

    @Test("After a nextval the next value is one step on, in either direction")
    func calledStepsOn() {
        #expect(PostgreSQLSequencePosition(lastValue: 41, isCalled: true)
            .nextValue(increment: 1, minValue: 1, maxValue: 1_000, cycles: false) == 42)
        #expect(PostgreSQLSequencePosition(lastValue: -10, isCalled: true)
            .nextValue(increment: -5, minValue: -1_000, maxValue: -1, cycles: false) == -15)
    }

    @Test("An exhausted sequence has no next value, and a cycling one starts over")
    func bounds() {
        let atMax = PostgreSQLSequencePosition(lastValue: .max, isCalled: true)
        #expect(atMax.nextValue(increment: 1, minValue: 1, maxValue: .max, cycles: false) == nil)
        #expect(atMax.nextValue(increment: 1, minValue: 1, maxValue: .max, cycles: true) == 1)
        let atMin = PostgreSQLSequencePosition(lastValue: -100, isCalled: true)
        #expect(atMin.nextValue(increment: -1, minValue: -100, maxValue: -1, cycles: true) == -1)
    }

    @Test("The position is read from the sequence relation itself")
    func positionQuery() {
        #expect(PostgreSQLSequencePosition.query(schema: "it's", sequence: "s\"q")
            == "SELECT last_value, is_called FROM \"it's\".\"s\"\"q\"")
        #expect(PostgreSQLSequencePosition(row: [.text("51"), .text("f")]) == PostgreSQLSequencePosition(
            lastValue: 51, isCalled: false
        ))
        #expect(PostgreSQLSequencePosition(row: [.null, .text("t")]) == nil)
    }
}
