import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

// Opening `evil.orders` must not reach a function or operator another role created in `evil`. The catalog entry pins
// the path for that; these statements also call pg_catalog by name, so they stay safe on a path the entry does not set:
// a schema-relative read, Redshift, CockroachDB, and the all-tables listing the app runs itself.
struct PostgreSQLCatalogQualificationTests {
    private static let schema = "evil"
    private static let table = "orders"
    private static let capabilities = PostgreSQLCapabilities(serverVersion: 170_011)

    // Words that take parentheses without naming a function the path resolves.
    private static let grammar: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "exists", "any", "all", "array", "case", "when", "then",
        "else", "coalesce", "nullif", "greatest", "least", "cast", "values", "over", "filter", "as", "on", "join",
        "using", "like", "ilike", "escape", "extract", "position", "substring", "trim", "row", "with", "union", "is",
        "operator"
    ]

    private static let call = try! NSRegularExpression(pattern: #"(?<![\w.$"])([A-Za-z_][A-Za-z0-9_]*)\s*\("#)

    static func unqualifiedCalls(in sql: String) -> [String] {
        let stripped = sql.replacingOccurrences(of: #"'(?:[^']|'')*'"#, with: "''", options: .regularExpression)
        let range = NSRange(stripped.startIndex..., in: stripped)
        return Self.call.matches(in: stripped, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: stripped) else { return nil }
            let name = String(stripped[nameRange])
            // A column list after an alias, `AS k(n)`, names no function.
            let before = stripped[..<nameRange.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            if before.hasSuffix(" as") || Self.grammar.contains(name.lowercased()) { return nil }
            return name
        }
    }

    private static var statements: [(String, String)] {
        [
            ("tableMetadata", PostgreSQLSchemaQueries.tableMetadata(schema: schema, table: table)),
            ("allTableMetadata", PostgreSQLSchemaQueries.allTableMetadata(schema: schema)),
            ("allTablesMetadata", PostgreSQLSchemaQueries.allTablesMetadata(schema: schema)),
            ("dependentEnumTypes", PostgreSQLSchemaQueries.dependentEnumTypes(schema: schema, table: table)),
            ("checkConstraintsQuery", PostgreSQLSchemaQueries.checkConstraintsQuery(schema: schema, table: table)),
            ("tableDDLColumnsQuery", PostgreSQLSchemaQueries.tableDDLColumnsQuery(
                schema: schema, table: table, capabilities: capabilities
            )),
            ("tableDDLConstraintsQuery", PostgreSQLSchemaQueries.tableDDLConstraintsQuery(schema: schema, table: table)),
            ("rebuildColumnsQuery", PostgreSQLSchemaQueries.rebuildColumnsQuery(
                schema: schema, table: table, capabilities: capabilities
            )),
            ("columnSpellingQuery", PostgreSQLSchemaQueries.columnSpellingQuery(
                schema: schema, table: table, capabilities: capabilities
            )),
            ("columnsQuery", PostgreSQLSchemaQueries.columnsQuery(
                schema: schema, table: table, capabilities: capabilities, includeMaterializedViews: true
            )),
            ("columnDDLQuery", PostgreSQLSchemaQueries.columnDDLQuery(schema: schema, table: table, capabilities: capabilities)),
            ("enumLabelQuery", PostgreSQLSchemaQueries.enumLabelQuery(schema: schema, table: table)),
            ("arrayTypeQuery", PostgreSQLSchemaQueries.arrayTypeQuery(schema: schema, table: table)),
            ("fetchPartitions", PostgreSQLSchemaQueries.fetchPartitions(schema: schema, table: table)),
            ("listSchemasRedshift", PostgreSQLSchemaQueries.listSchemasRedshift),
            ("currentSchema", PostgreSQLSchemaQueries.currentSchema),
            ("firstSearchPathSchema", PostgreSQLSchemaQueries.firstSearchPathSchema),
            ("triggerList", PostgreSQLObjectQueries.triggerList(schema: schema, table: table)),
            ("routineList", PostgreSQLObjectQueries.routineList(schema: schema, capabilities: capabilities)),
            ("userDefinedTypeList", PostgreSQLObjectQueries.userDefinedTypeList(
                schema: schema, identity: nil, capabilities: capabilities
            )),
            ("indexList", PostgreSQLIndexQueries.indexList(schema: schema, table: table, capabilities: capabilities)),
            ("standaloneIndexQuery", PostgreSQLIndexQueries.standaloneIndexQuery(schema: schema, table: table)),
            ("postGISProbe", PostGISSpatialRewrite.probeQuery),
            ("schemaOwnerAndComment", PostgreSQLSchemaManagementQueries.ownerAndComment(schema: schema)),
            ("schemaGrants", PostgreSQLSchemaManagementQueries.grants(schema: schema)),
            ("pgvectorProbe", PgvectorTypes.probeQuery),
            ("enumTypeOidQuery", PostgreSQLSchemaQueries.enumTypeOidQuery),
            ("catalogPresence", PostgreSQLCatalogPresence.probeQuery),
            ("typeNameLookup", PostgreSQLCatalogTypeNames.lookupQuery(oids: [16_385]) ?? "")
        ]
    }

    @Test("Every catalog statement for evil.orders calls built-ins through pg_catalog")
    func everyCallIsQualified() {
        for (label, sql) in Self.statements {
            let bare = Self.unqualifiedCalls(in: sql)
            #expect(bare.isEmpty, "\(label) calls \(bare) without pg_catalog:\n\(sql)")
        }
    }

    @Test("The checker finds the bare calls the size read used to send")
    func checkerFindsBareCalls() {
        let reported = """
            SELECT pg_total_relation_size(c.oid), obj_description(c.oid, 'pg_class'), c.reltuples::bigint
            FROM pg_class c WHERE c.relname = 'orders'
            """
        #expect(Self.unqualifiedCalls(in: reported) == ["pg_total_relation_size", "obj_description"])
    }

    // The schema-relative read runs with `evil` on the path, so no operand may need a cast to reach pg_catalog's
    // operator: `typelem <> 0` is oid against integer, which a `<>(oid, integer)` in `evil` takes exactly.
    @Test("The schema-relative column read compares oids with oids")
    func relativeColumnReadComparesExactTypes() {
        let sql = PostgreSQLSchemaQueries.columnSpellingQuery(schema: Self.schema, table: Self.table, capabilities: Self.capabilities)
        #expect(sql.contains("dt.typelem <> 0::pg_catalog.oid"))
        #expect(sql.contains("dd.classid = 'pg_catalog.pg_type'::pg_catalog.regclass::pg_catalog.oid"))
        #expect(!sql.contains("information_schema"))
    }

    // Measured on 17.11: `SELECT pg_catalog.current_user` fails with "missing FROM-clause entry for table pg_catalog".
    @Test("The schema details read names the current role with the keyword")
    func schemaDetailsReadsCurrentUserAsAKeyword() {
        let sql = PostgreSQLSchemaManagementQueries.ownerAndComment(schema: Self.schema)
        #expect(sql.contains("CURRENT_USER"))
        #expect(!sql.contains("pg_catalog.current_user"))
    }

    // A database owner can give the session a default path that names its schema before pg_catalog, where an operator
    // of identical signature wins. These run on that path, so each names pg_catalog's operator or uses none.
    @Test("Statements sent on the session's own path name pg_catalog's operators")
    func sessionPathStatementsNamePgCatalogOperators() throws {
        let statements = [
            PostgreSQLSchemaQueries.allTablesMetadata(schema: Self.schema),
            PostgreSQLSessionScopeSQL.captureStatement(names: ["DateStyle", "TimeZone"]).sql,
            PostgreSQLRoutineDebugProtocol.backendCountStatement(process: 42),
            PostgreSQLRoutineDebugProtocol.routineSourceStatement(oid: 16_385),
            try #require(PostgreSQLRoutineDebugProtocol.targetDefaultsStatement(oid: 16_385, argumentCount: 2)),
            try #require(PostGISSpatialRewrite.conversionQuery(for: PostGISType(name: "geometry", schema: Self.schema)))
        ]
        for sql in statements {
            #expect(!sql.contains(" = ") && !sql.contains(" <> ") && !sql.contains(" IN ("), "\(sql)")
            #expect(Self.unqualifiedCalls(in: sql).isEmpty, "\(sql)")
        }
    }

    @Test("The debugger reads no defaults for a routine without arguments")
    func noDefaultsStatementWithoutArguments() {
        #expect(PostgreSQLRoutineDebugProtocol.targetDefaultsStatement(oid: 16_385, argumentCount: 0) == nil)
    }

    // Sent on the user's session after a result with a type created since connect, so under that session's path.
    @Test("The type-name lookup compares oids with oids")
    func typeNameLookupComparesOids() throws {
        let sql = try #require(PostgreSQLCatalogTypeNames.lookupQuery(oids: [16_385]))
        #expect(sql.contains("WHERE t.oid IN ('16385'::pg_catalog.oid)"))
    }

    @Test("The trigger listing masks tgtype as an integer, which pg_catalog's & takes exactly")
    func triggerMasksAreExact() {
        let sql = PostgreSQLObjectQueries.triggerList(schema: Self.schema, table: Self.table)
        #expect(!sql.contains("(t.tgtype &"))
        #expect(sql.contains("(t.tgtype::pg_catalog.int4 & 64) <> 0"))
    }

    @Test("The type listing compares collation and support-function oids with oids")
    func typeListingComparesExactTypes() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: Self.schema, identity: nil, capabilities: Self.capabilities
        )
        #expect(!sql.contains("collation <> 0 "))
        #expect(!sql.contains("rngcanonical <> 0"))
        #expect(sql.contains("r.rngcanonical::pg_catalog.oid <> 0::pg_catalog.oid"))
    }

    @Test("The column read leaves the path-dependent spellings to the schema-relative read")
    func columnsQueryDeparsesNothing() {
        let sql = PostgreSQLSchemaQueries.columnsQuery(
            schema: Self.schema, table: Self.table, capabilities: Self.capabilities, includeMaterializedViews: true
        )
        #expect(!sql.contains("pg_get_expr"))
        #expect(!sql.contains("format_type(a.atttypid, a.atttypmod)"))
        #expect(!sql.contains("c.column_default"))
    }
}
