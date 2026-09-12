//
//  PostgreSQLViewDefinitionTests.swift
//  TableProTests
//
//  Tests for PostgreSQLViewDefinition (compiled via project.yml from PostgreSQLDriverPlugin).
//  The catalog values below are what PostgreSQL 17.11 returns for the objects described.
//

import Foundation
import Testing

@Suite("PostgreSQL view definition")
struct PostgreSQLViewDefinitionTests {
    private let body = " SELECT id,\n    v\n   FROM sales.orders\n  WHERE (id > 0);"

    private func row(
        kind: PostgreSQLViewDefinition.Kind,
        options: [String] = [],
        accessMethod: String? = nil,
        tablespace: String? = nil
    ) -> PostgreSQLViewDefinition.CatalogRow {
        PostgreSQLViewDefinition.CatalogRow(
            kind: kind,
            query: body,
            options: options,
            accessMethod: accessMethod,
            tablespace: tablespace
        )
    }

    // MARK: - Views

    @Test("A plain view is a CREATE OR REPLACE VIEW ending in one semicolon")
    func plainView() {
        let sql = PostgreSQLViewDefinition.statement(name: "vw", schema: "sales", row: row(kind: .view))

        #expect(sql == """
            CREATE OR REPLACE VIEW "sales"."vw" AS
             SELECT id,
                v
               FROM sales.orders
              WHERE (id > 0);
            """)
        #expect(!sql.hasSuffix(";;"))
    }

    /// `CREATE OR REPLACE VIEW` replaces the options it does not name, so a definition that left
    /// these out turned a `security_barrier` or `security_invoker` view into an unrestricted one and
    /// dropped its check option. Measured on 17.11: reloptions went to NULL and a role with rights
    /// on the view alone could then read the base table through it.
    @Test("A view keeps its options and its check option")
    func viewKeepsOptionsAndCheckOption() {
        let sql = PostgreSQLViewDefinition.statement(
            name: "vw",
            schema: "sales",
            row: row(
                kind: .view,
                options: ["security_barrier=true", "security_invoker=true", "check_option=cascaded"]
            )
        )

        #expect(sql.hasPrefix(
            "CREATE OR REPLACE VIEW \"sales\".\"vw\" WITH (security_barrier='true', security_invoker='true') AS"
        ))
        #expect(sql.hasSuffix("\n  WITH CASCADED CHECK OPTION;"))
        #expect(!sql.contains("check_option"))
    }

    @Test("A local check option is named as such")
    func localCheckOption() {
        let sql = PostgreSQLViewDefinition.statement(
            name: "vw", schema: "sales", row: row(kind: .view, options: ["check_option=local"])
        )

        #expect(sql.hasSuffix("\n  WITH LOCAL CHECK OPTION;"))
        #expect(!sql.contains("WITH ("))
    }

    // MARK: - Materialized views

    @Test("A materialized view is a CREATE MATERIALIZED VIEW")
    func plainMaterializedView() {
        let sql = PostgreSQLViewDefinition.statement(
            name: "mv", schema: "sales", row: row(kind: .materializedView, accessMethod: "heap")
        )

        #expect(sql.hasPrefix("CREATE MATERIALIZED VIEW \"sales\".\"mv\" AS\n"))
        #expect(sql.hasSuffix(";"))
    }

    /// `USING` does not exist before PostgreSQL 12 and `heap` is what a server creates without it,
    /// so it is written only for a view that is actually stored another way.
    @Test("Only a non-default access method is written")
    func accessMethodOnlyWhenNotHeap() {
        let sql = PostgreSQLViewDefinition.statement(
            name: "mv",
            schema: "sales",
            row: row(kind: .materializedView, accessMethod: "columnar", tablespace: "fast")
        )

        #expect(sql.hasPrefix("CREATE MATERIALIZED VIEW \"sales\".\"mv\" USING \"columnar\" TABLESPACE \"fast\" AS\n"))
    }

    @Test("A materialized view keeps its storage parameters")
    func materializedViewKeepsStorageParameters() {
        let sql = PostgreSQLViewDefinition.statement(
            name: "mv", schema: "sales", row: row(kind: .materializedView, options: ["fillfactor=70"])
        )

        #expect(sql.contains("WITH (fillfactor='70')"))
    }

    /// Population is the view's data state rather than part of its definition. Writing `WITH NO
    /// DATA` into it would make two otherwise identical views compare as different and have schema
    /// sync drop and recreate one, losing its rows.
    @Test("Population state is not part of the statement")
    func populationIsNotInTheStatement() {
        let sql = PostgreSQLViewDefinition.statement(
            name: "mv", schema: "sales", row: row(kind: .materializedView)
        )

        #expect(!sql.contains("WITH NO DATA"))
        #expect(!sql.contains("WITH DATA"))
    }

    // MARK: - Catalog parsing

    @Test("relkind selects the kind, and anything else is not a view")
    func relkindMapping() {
        #expect(PostgreSQLViewDefinition.kind(forRelkind: "v") == .view)
        #expect(PostgreSQLViewDefinition.kind(forRelkind: "m") == .materializedView)
        for relkind in ["r", "p", "f", "i", "S", "t", ""] {
            #expect(PostgreSQLViewDefinition.kind(forRelkind: relkind) == nil)
        }
    }

    /// `reloptions` is read as array text: `array_to_json` does not exist on PostgreSQL 9.1. The
    /// array decoder honours quoting, so a value holding a comma or a quote stays one option.
    @Test("Options are decoded from the array text, commas and quotes inside a value included")
    func optionsDecodedFromArrayText() {
        let options: (String?) -> [String]? = { text in
            PostgreSQLViewDefinition.parse(row: ["v", "SELECT 1", text, nil, nil])?.options
        }
        #expect(options("{security_barrier=true}") == ["security_barrier=true"])
        #expect(options("{fillfactor=70,autovacuum_enabled=false}") == ["fillfactor=70", "autovacuum_enabled=false"])
        #expect(options(#"{"note=a, b","q=\"x\""}"#) == ["note=a, b", #"q="x""#])
        #expect(options(nil)?.isEmpty == true)
    }

    @Test("A catalog row parses into the kind, query, options and storage")
    func parseRow() {
        let parsed = PostgreSQLViewDefinition.parse(row: [
            "m", body, "{fillfactor=70}", "heap", "fast"
        ])

        #expect(parsed?.kind == .materializedView)
        #expect(parsed?.query == body)
        #expect(parsed?.options == ["fillfactor=70"])
        #expect(parsed?.accessMethod == "heap")
        #expect(parsed?.tablespace == "fast")
    }

    @Test("A row for something that is not a view parses to nothing")
    func parseRejectsOtherKinds() {
        #expect(PostgreSQLViewDefinition.parse(row: ["r", body, nil, nil, nil]) == nil)
        #expect(PostgreSQLViewDefinition.parse(row: [nil, nil, nil, nil, nil]) == nil)
        #expect(PostgreSQLViewDefinition.parse(row: ["v", body]) == nil)
    }

    /// The body is read with `search_path` narrowed to `pg_catalog`, so every name in it is qualified and the text
    /// binds to the same tables wherever it is run.
    @Test("The catalog query narrows the search path and addresses the view by schema and name")
    func catalogQueryIsQualifiedAndScoped() {
        let query = PostgreSQLViewDefinition.catalogQuery(name: "vw", schema: "sales")

        #expect(PostgreSQLViewDefinition.qualifiedReadPrefix == "SET LOCAL search_path = pg_catalog; ")
        #expect(query.contains("pg_catalog.pg_get_viewdef(c.oid, true)"))
        #expect(query.contains("n.nspname = 'sales'"))
        #expect(query.contains("c.relname = 'vw'"))
        #expect(query.contains("c.relkind IN ('v', 'm')"))
        #expect(query.contains("c.reloptions::text"))
        #expect(!query.contains("json"))
    }

    @Test("A name that needs quoting is quoted, and a literal that needs escaping is escaped")
    func catalogQueryQuotesIdentifiers() {
        let query = PostgreSQLViewDefinition.catalogQuery(name: "it's", schema: "My \"Odd\" Schema")

        #expect(query.contains("c.relname = 'it''s'"))
        #expect(query.contains("n.nspname = 'My \"Odd\" Schema'"))
    }
}
