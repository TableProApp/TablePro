//
//  PostgreSQLColumnQueryTests.swift
//  TableProTests
//
//  Tests for the PostgreSQL and Redshift column introspection query builders
//  (compiled via symlink from PostgreSQLDriverPlugin). Regression cover for
//  autocomplete that ignored the requested schema and always queried the
//  active schema, so columns of a schema-qualified table like `s2.orders`
//  never resolved.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.columnsQuery")
struct PostgreSQLColumnsQueryTests {
    private let modern = PostgreSQLCapabilities(serverVersion: 170_000)
    private let legacy = PostgreSQLCapabilities(serverVersion: 90_100)

    private func singleTable(schema: String, table: String) -> String {
        PostgreSQLSchemaQueries.columnsQuery(
            schema: schema,
            table: table,
            capabilities: modern,
            includeMaterializedViews: true
        )
    }

    private func allTables(schema: String) -> String {
        PostgreSQLSchemaQueries.columnsQuery(
            schema: schema,
            table: nil,
            capabilities: legacy,
            includeMaterializedViews: false
        )
    }

    @Test("single-table query filters on the requested schema and table")
    func singleTableFiltersOnRequestedSchema() {
        let query = singleTable(schema: "s2", table: "orders")
        #expect(query.contains("WHERE c.table_schema = 's2' AND c.table_name = 'orders'"))
        #expect(query.contains("AND tc.table_schema = 's2'"))
        #expect(query.contains("AND tc.table_name = 'orders'"))
    }

    @Test("a non-active schema is not ignored", arguments: ["s2", "analytics", "public"])
    func nonActiveSchemaThreadsThrough(schema: String) {
        let query = singleTable(schema: schema, table: "orders")
        #expect(query.contains("c.table_schema = '\(schema)'"))
    }

    @Test("queries for different schemas differ in the schema literal")
    func differentSchemasProduceDifferentQueries() {
        #expect(singleTable(schema: "s1", table: "t") != singleTable(schema: "s2", table: "t"))
    }

    @Test("single-table query omits the table_name column and orders by ordinal")
    func singleTableOmitsTableNameColumn() {
        let query = singleTable(schema: "s2", table: "orders")
        #expect(!query.contains("c.table_name,"))
        #expect(query.contains("ORDER BY cols.ordinal_position"))
        #expect(!query.contains("ORDER BY c.ordinal_position"))
        #expect(query.contains("pk ON c.column_name = pk.column_name"))
    }

    @Test("all-tables query selects table_name, drops the table filter, and orders by table")
    func allTablesProjectsTableName() {
        let query = allTables(schema: "s2")
        #expect(query.contains("c.table_name AS table_name,"))
        #expect(query.contains("WHERE c.table_schema = 's2'"))
        #expect(!query.contains("c.table_name = '"))
        #expect(query.contains("ORDER BY cols.table_name, cols.ordinal_position"))
        #expect(!query.contains("ORDER BY c.table_name, c.ordinal_position"))
        #expect(query.contains("pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name"))
    }

    @Test("identity and generated flags are read from pg_attribute by attribute number on 10 and later")
    func modernServerReadsAttributes() {
        let query = singleTable(schema: "s2", table: "orders")
        #expect(query.contains("a.attidentity"))
        #expect(query.contains("a.attgenerated"))
        #expect(query.contains("c.generation_expression"))
        #expect(query.contains("ON a.attrelid = rel.oid"))
        #expect(query.contains("AND a.attnum = c.ordinal_position"))
    }

    /// Re-pinned deliberately: the join itself is no longer version-gated, because the declared
    /// type is `format_type(a.atttypid, a.atttypmod)` and every server back to 9.1 has both. What
    /// stays gated is the two attributes 9.1 does not have.
    @Test("a server without identity or generated columns reads no attidentity or attgenerated")
    func legacyServerSkipsAttributes() {
        let query = allTables(schema: "s2")
        #expect(query.contains("pg_catalog.pg_attribute a"))
        #expect(!query.contains("a.attidentity"))
        #expect(!query.contains("a.attgenerated"))
        #expect(!query.contains("c.generation_expression"))
    }

    @Test("both the modern and the legacy query read the declared type and the domain name")
    func everyServerReadsTheDeclaredType() {
        for query in [singleTable(schema: "s2", table: "orders"), allTables(schema: "s2")] {
            #expect(query.contains("pg_catalog.format_type(a.atttypid, a.atttypmod)"))
            #expect(query.contains("AS declared_type"))
            #expect(query.contains("c.domain_name AS domain_name"))
            #expect(query.contains("ON a.attrelid = rel.oid"))
            #expect(query.contains("AND a.attnum = c.ordinal_position"))
        }
    }

    @Test("column comments are read through the relation's pg_class oid, not a statistics view")
    func commentsKeyOnRelationOid() {
        for query in [singleTable(schema: "s2", table: "orders"), allTables(schema: "s2")] {
            #expect(!query.contains("pg_statio_all_tables"))
            #expect(query.contains("ON rel.relnamespace = relns.oid"))
            #expect(query.contains("pg_catalog.col_description(rel.oid, c.ordinal_position)"))
        }
    }

    @Test("primary key columns are matched to the constraint's own table")
    func primaryKeyJoinIsTableScoped() {
        for query in [singleTable(schema: "s2", table: "orders"), allTables(schema: "s2")] {
            #expect(query.contains("AND tc.table_name = kcu.table_name"))
        }
    }
}

@Suite("PostgreSQLSchemaQueries.columnsQuery materialized views")
struct PostgreSQLMaterializedViewColumnsQueryTests {
    private let modern = PostgreSQLCapabilities(serverVersion: 170_000)
    private let legacy = PostgreSQLCapabilities(serverVersion: 90_100)

    private static let armMarkers = [
        "UNION ALL",
        "mvc.relkind = 'm'",
        "pg_catalog.pg_attribute mva",
        "pg_catalog.format_type(mva.atttypid"
    ]

    private static let outerColumns = [
        "cols.column_name",
        "cols.data_type",
        "cols.is_nullable",
        "cols.column_default",
        "cols.collation_name",
        "cols.column_comment",
        "cols.udt_name",
        "cols.is_pk",
        "cols.identity_kind",
        "cols.generated_kind",
        "cols.udt_schema",
        "cols.generation_expression",
        "cols.declared_type",
        "cols.domain_name"
    ]

    private func query(
        schema: String = "s2",
        table: String? = "orders",
        capabilities: PostgreSQLCapabilities? = nil,
        includeMaterializedViews: Bool = true
    ) -> String {
        PostgreSQLSchemaQueries.columnsQuery(
            schema: schema,
            table: table,
            capabilities: capabilities ?? modern,
            includeMaterializedViews: includeMaterializedViews
        )
    }

    @Test("the materialized view arm appears only when the catalog has materialized views")
    func armFollowsTheFlag() {
        let included = query()
        let excluded = query(includeMaterializedViews: false)
        for marker in Self.armMarkers {
            #expect(included.contains(marker))
            #expect(!excluded.contains(marker))
        }
    }

    @Test("the outer projection is exactly the order the row mapper reads")
    func outerProjectionMatchesMapperOrder() {
        let singleTable = query()
        #expect(singleTable.contains("SELECT\n    \(Self.outerColumns.joined(separator: ",\n    "))\nFROM ("))
        let allTables = query(table: nil)
        let withTableName = ["cols.table_name"] + Self.outerColumns
        #expect(allTables.contains("SELECT\n    \(withTableName.joined(separator: ",\n    "))\nFROM ("))
        for rendered in [singleTable, allTables] {
            #expect(!rendered.contains("cols.ordinal_position,"))
        }
    }

    @Test("ordering carries through the union on the derived table's ordinal")
    func orderingCarriesThroughTheUnion() {
        #expect(query().contains("ORDER BY cols.ordinal_position"))
        #expect(query(table: nil).contains("ORDER BY cols.table_name, cols.ordinal_position"))
    }

    @Test("the arm is scoped to the same schema and table as the information_schema arm",
          arguments: ["s2", "analytics", "public"])
    func armIsScopedLikeTheBase(schema: String) {
        let singleTable = query(schema: schema)
        #expect(singleTable.contains("mvn.nspname = '\(schema)'"))
        #expect(singleTable.contains("mvc.relname = 'orders'"))
        let allTables = query(schema: schema, table: nil)
        #expect(allTables.contains("mvc.relname AS table_name"))
        #expect(!allTables.contains("mvc.relname = '"))
    }

    @Test("a materialized view column has no primary key and no default")
    func armSkipsConstraintsAndDefaults() {
        let rendered = query()
        #expect(rendered.contains("'NO' AS is_pk"))
        #expect(rendered.contains("NULL::text AS column_default"))
        #expect(!rendered.contains("pg_attrdef"))
        #expect(rendered.components(separatedBy: "information_schema.table_constraints").count - 1 == 1)
    }

    @Test("identity and generated mirror the capability switches the base arm uses")
    func armMirrorsCapabilitySwitches() {
        let modernQuery = query()
        #expect(modernQuery.contains("mva.attidentity AS identity_kind"))
        #expect(modernQuery.contains("mva.attgenerated AS generated_kind"))
        let legacyQuery = query(capabilities: legacy)
        #expect(legacyQuery.contains("mvc.relkind = 'm'"))
        #expect(!legacyQuery.contains("mva.attidentity"))
        #expect(!legacyQuery.contains("mva.attgenerated"))
    }

    @Test("classified type names are spelled the way information_schema spells them, without a typmod")
    func armSpellsTypesLikeInformationSchema() {
        let rendered = query()
        #expect(rendered.contains("pg_catalog.format_type(mva.atttypid, NULL)"))
        #expect(rendered.contains("pg_catalog.format_type(mvt.typbasetype, NULL)"))
    }

    @Test("the declared type carries the modifier and the domain name comes from the type itself")
    func armReadsTheDeclaredType() {
        let rendered = query()
        #expect(rendered.contains("pg_catalog.format_type(mva.atttypid, mva.atttypmod)"))
        #expect(rendered.contains("AS declared_type"))
        #expect(rendered.contains("CASE WHEN mvt.typtype = 'd' THEN mvt.typname END AS domain_name"))
    }

    @Test("a domain resolves to its base type, as information_schema does")
    func armResolvesDomainsToBaseTypes() {
        let rendered = query()
        #expect(rendered.contains("mvt.typtype = 'd'"))
        #expect(rendered.contains("mvbt.oid = mvt.typbasetype"))
        #expect(rendered.contains("COALESCE(mvbt.typname, mvt.typname) AS udt_name"))
        #expect(rendered.contains("COALESCE(mvbtn.nspname, mvtn.nspname) AS udt_schema"))
    }

    @Test("the default collation is reported as absent rather than as a collation named default")
    func armSuppressesTheDefaultCollation() {
        let rendered = query()
        #expect(rendered.contains(
            "CASE WHEN mvcon.nspname <> 'pg_catalog' OR mvco.collname <> 'default' "
                + "THEN mvco.collname END AS collation_name"
        ))
    }

    @Test("the arm carries the comment source and the visibility filters information_schema applies")
    func armKeepsCommentsAndPrivileges() {
        let rendered = query()
        #expect(rendered.contains("pg_catalog.col_description(mvc.oid, mva.attnum) AS column_comment"))
        #expect(rendered.contains("pg_catalog.pg_has_role(mvc.relowner"))
        #expect(rendered.contains("pg_catalog.has_column_privilege(mvc.oid"))
        #expect(rendered.contains("NOT pg_catalog.pg_is_other_temp_schema(mvn.oid)"))
    }
}

@Suite("RedshiftSchemaQueries.columnsQuery")
struct RedshiftColumnsQueryTests {
    @Test("single-table query filters on the requested schema and table")
    func singleTableFiltersOnRequestedSchema() {
        let query = RedshiftSchemaQueries.columnsQuery(schema: "s2", table: "orders")
        #expect(query.contains("WHERE c.table_schema = 's2' AND c.table_name = 'orders'"))
        #expect(query.contains("AND tc.table_schema = 's2'"))
        #expect(query.contains("AND tc.table_name = 'orders'"))
        #expect(!query.contains("c.table_name,"))
        #expect(query.contains("ORDER BY c.ordinal_position"))
    }

    @Test("a non-active schema is not ignored", arguments: ["s2", "analytics", "public"])
    func nonActiveSchemaThreadsThrough(schema: String) {
        let query = RedshiftSchemaQueries.columnsQuery(schema: schema, table: "orders")
        #expect(query.contains("c.table_schema = '\(schema)'"))
    }

    @Test("all-tables query selects table_name, drops the table filter, and orders by table")
    func allTablesProjectsTableName() {
        let query = RedshiftSchemaQueries.columnsQuery(schema: "s2", table: nil)
        #expect(query.contains("c.table_name,"))
        #expect(query.contains("WHERE c.table_schema = 's2'"))
        #expect(!query.contains("c.table_name = '"))
        #expect(query.contains("ORDER BY c.table_name, c.ordinal_position"))
        #expect(query.contains("pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name"))
    }

    @Test("primary key columns are matched to the constraint's own table")
    func primaryKeyJoinIsTableScoped() {
        for table in ["orders", nil] {
            let query = RedshiftSchemaQueries.columnsQuery(schema: "s2", table: table)
            #expect(query.contains("AND tc.table_name = kcu.table_name"))
        }
    }

    @Test("Redshift keeps a single-arm read and never names relkind")
    func redshiftKeepsASingleArmRead() {
        for table in ["orders", nil] {
            let query = RedshiftSchemaQueries.columnsQuery(schema: "s2", table: table)
            #expect(!query.contains("UNION ALL"))
            #expect(!query.contains("relkind"))
        }
    }
}

@Suite("PostgreSQLSchemaQueries.columnDDLQuery")
struct PostgreSQLColumnDDLQueryTests {
    private let modern = PostgreSQLCapabilities(serverVersion: 170_000)
    private let legacy = PostgreSQLCapabilities(serverVersion: 90_100)

    @Test("Spells the type with format_type over its own modifier and deparses the stored expression")
    func readsTypeAndExpression() {
        let query = PostgreSQLSchemaQueries.columnDDLQuery(schema: "public", table: "places", capabilities: modern)
        #expect(query.contains("pg_catalog.format_type(a.atttypid, a.atttypmod)"))
        #expect(query.contains("pg_catalog.pg_get_expr(ad.adbin, ad.adrelid)"))
        #expect(query.contains("LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum"))
        #expect(query.contains("WHERE n.nspname = 'public'"))
        #expect(query.contains("AND c.relname = 'places'"))
    }

    @Test("Asks pg_depend which sequences the stored expression reads, matching the relation catalog only")
    func detectsSequenceDependency() {
        let query = PostgreSQLSchemaQueries.columnDDLQuery(schema: "public", table: nil, capabilities: modern)
        #expect(query.contains("dep.classid = 'pg_catalog.pg_attrdef'::pg_catalog.regclass"))
        #expect(query.contains("AND dep.objid = ad.oid"))
        #expect(query.contains("AND dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass"))
        #expect(query.contains("AND seq.relkind = 'S'"))
    }

    @Test("Reads attgenerated only where the server has generated columns")
    func generatedFlagFollowsCapabilities() {
        #expect(PostgreSQLSchemaQueries.columnDDLQuery(schema: "s", table: nil, capabilities: modern)
            .contains("a.attgenerated::text"))
        #expect(!PostgreSQLSchemaQueries.columnDDLQuery(schema: "s", table: nil, capabilities: legacy)
            .contains("attgenerated"))
    }

    @Test("Covers every relation kind the column read can return, and no system or dropped attribute")
    func coversColumnReadRelations() {
        let query = PostgreSQLSchemaQueries.columnDDLQuery(schema: "public", table: nil, capabilities: modern)
        #expect(query.contains("c.relkind IN ('r', 'v', 'f', 'p', 'm')"))
        #expect(query.contains("a.attnum > 0"))
        #expect(query.contains("NOT a.attisdropped"))
        #expect(!query.contains("c.relname ="))
    }

    @Test("A quote in the schema or relation name stays inside its literal")
    func quotesNamesAsLiterals() {
        let query = PostgreSQLSchemaQueries.columnDDLQuery(
            schema: "o'hara", table: "x'; DROP TABLE t; --", capabilities: modern
        )
        #expect(query.contains("n.nspname = 'o''hara'"))
        #expect(query.contains("c.relname = 'x''; DROP TABLE t; --'"))
    }
}

@Suite("PostgreSQLSchemaQueries.columnDDL")
struct PostgreSQLColumnDDLParsingTests {
    private func row(
        _ table: String?,
        _ column: String?,
        _ spelling: String?,
        _ expression: String? = nil,
        generated: String = "",
        qualifiedSequences: String? = nil,
        relativeSequences: String? = nil,
        standardConformingStrings: String? = "on",
        collation: String? = nil
    ) -> [PluginCellValue] {
        [
            table, column, spelling, expression, generated,
            qualifiedSequences, relativeSequences, standardConformingStrings, collation
        ].map { $0.map(PluginCellValue.text) ?? .null }
    }

    @Test("Keys each column's clauses by relation and column")
    func keysByRelationAndColumn() {
        let columns = PostgreSQLSchemaQueries.columnDDL(rows: [
            row("places", "shape", "public.geometry(Point,4326)", "public.st_geomfromtext('POINT(0 0)'::text, 4326)"),
            row("orders", "status", "public.status", "'new'::public.status")
        ])
        #expect(columns["places"]?["shape"]?.typeSpelling == "public.geometry(Point,4326)")
        #expect(columns["places"]?["shape"]?.defaultExpression == "public.st_geomfromtext('POINT(0 0)'::text, 4326)")
        #expect(columns["orders"]?["status"]?.defaultExpression == "'new'::public.status")
    }

    @Test("A default that reads a sequence beside the table writes that sequence relative and the rest qualified")
    func sequenceDefaultKeepsOnlyTheSequenceRelative() {
        let columns = PostgreSQLSchemaQueries.columnDDL(rows: [
            row(
                "orders", "id", "integer", "sales.wrap(nextval('sales.orders_id_seq'::regclass))",
                qualifiedSequences: "{sales.orders_id_seq}", relativeSequences: "{orders_id_seq}"
            )
        ])
        #expect(columns["orders"]?["id"]?.typeSpelling == "integer")
        #expect(columns["orders"]?["id"]?.defaultExpression == "sales.wrap(nextval('orders_id_seq'::regclass))")
    }

    @Test("A generated column's expression is its generation expression, not a default")
    func generatedExpressionIsNotADefault() {
        let columns = PostgreSQLSchemaQueries.columnDDL(rows: [
            row("gen_t", "area", "double precision", "public.st_x(shape)", generated: "s")
        ])
        #expect(columns["gen_t"]?["area"]?.generationExpression == "public.st_x(shape)")
        #expect(columns["gen_t"]?["area"]?.defaultExpression == nil)
    }

    @Test("Two relations whose names differ only in case keep their own clauses")
    func keepsExactCase() {
        let columns = PostgreSQLSchemaQueries.columnDDL(rows: [
            row("Orders", "id", "bigint"),
            row("orders", "id", "integer")
        ])
        #expect(columns["Orders"]?["id"]?.typeSpelling == "bigint")
        #expect(columns["orders"]?["id"]?.typeSpelling == "integer")
    }

    @Test("A row missing its type spelling contributes nothing")
    func skipsIncompleteRows() {
        let columns = PostgreSQLSchemaQueries.columnDDL(rows: [
            row("places", "shape", nil),
            row("places", "label", ""),
            row(nil, "id", "integer")
        ])
        #expect(columns.isEmpty)
    }
}
