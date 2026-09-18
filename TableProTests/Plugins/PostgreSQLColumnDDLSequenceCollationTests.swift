//
//  PostgreSQLColumnDDLSequenceCollationTests.swift
//  TableProTests
//
//  The column DDL read's sequence arrays and collation, and the sequence listing a copy recreates
//  those sequences from.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.columnDDLQuery sequences and collation")
struct PostgreSQLColumnDDLQuerySequenceCollationTests {
    private let query = PostgreSQLSchemaQueries.columnDDLQuery(
        schema: "sales", table: "orders", capabilities: PostgreSQLCapabilities(serverVersion: 170_000)
    )

    @Test("Reads the qualified and relative names of the default's sequences as two arrays in one order")
    func readsBothSequenceArraysInOneOrder() {
        #expect(query.contains(
            "pg_catalog.array_agg(seq.oid::pg_catalog.regclass::pg_catalog.text ORDER BY seq.oid)"
        ))
        #expect(query.contains("pg_catalog.array_agg(pg_catalog.quote_ident(seq.relname) ORDER BY seq.oid)"))
        #expect(query.components(separatedBy: "ORDER BY seq.oid").count - 1 == 2)
    }

    @Test("Lists only sequences in the table's own schema that this column's default depends on")
    func sequencesAreOwnSchemaDependencies() {
        #expect(query.contains(PostgreSQLSequenceQueries.columnDefaultDependency(alias: "dep")))
        #expect(query.components(separatedBy: "AND dep.objid = ad.oid").count - 1 == 2)
        #expect(query.components(separatedBy: "AND seq.relkind = 'S'").count - 1 == 2)
        #expect(query.components(separatedBy: "AND seq.relnamespace = c.relnamespace").count - 1 == 2)
    }

    @Test("Reads standard_conforming_strings in the same statement as the deparsed default")
    func readsQuotingSetting() {
        #expect(query.contains("pg_catalog.current_setting('standard_conforming_strings')"))
    }

    @Test("Reads a collation only where it differs from the type's, qualified and quoted")
    func readsCollationOnlyWhereDeclared() {
        #expect(query.contains(PostgreSQLSchemaQueries.columnCollation))
        #expect(PostgreSQLSchemaQueries.columnCollation.contains("a.attcollation <> 0"))
        #expect(PostgreSQLSchemaQueries.columnCollation.contains(
            "a.attcollation <> (SELECT ty.typcollation FROM pg_catalog.pg_type ty WHERE ty.oid = a.atttypid)"
        ))
        #expect(PostgreSQLSchemaQueries.columnCollation.contains(PostgreSQLObjectQueries.collationName("a.attcollation")))
        #expect(PostgreSQLObjectQueries.collationName("a.attcollation").contains(
            "pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(co.collname)"
        ))
    }

    @Test("The DDL builders' clause is the same collation behind a COLLATE keyword, or nothing")
    func collateClauseWrapsTheSameCollation() {
        #expect(
            PostgreSQLSchemaQueries.columnCollateClause
                == "COALESCE(' COLLATE ' || \(PostgreSQLSchemaQueries.columnCollation), '')"
        )
    }
}

@Suite("PostgreSQLSchemaQueries.columnDDL sequences and collation")
struct PostgreSQLColumnDDLParsingSequenceCollationTests {
    private func row(
        _ expression: String?,
        generated: String = "",
        qualified: String? = nil,
        relative: String? = nil,
        standardConformingStrings: String? = "on",
        collation: String? = nil
    ) -> [PluginCellValue] {
        ["orders", "id", "bigint", expression, generated, qualified, relative, standardConformingStrings, collation]
            .map { $0.map(PluginCellValue.text) ?? .null }
    }

    private func parsed(_ row: [PluginCellValue]) -> PostgreSQLCatalogColumnDDL? {
        PostgreSQLSchemaQueries.columnDDL(rows: [row])["orders"]?["id"]
    }

    @Test("A default reading two sequences beside the table writes both relative")
    func relativizesEveryListedSequence() {
        let column = parsed(row(
            #"(nextval('sales.orders_id_seq'::regclass) + nextval('sales."UPPER"'::regclass))"#,
            qualified: #"{sales.orders_id_seq,"sales.\"UPPER\""}"#,
            relative: #"{orders_id_seq,"\"UPPER\""}"#
        ))
        #expect(column?.defaultExpression == #"(nextval('orders_id_seq'::regclass) + nextval('"UPPER"'::regclass))"#)
    }

    @Test("A default reading only another schema's sequence keeps it qualified")
    func otherSchemaSequenceStaysQualified() {
        #expect(parsed(row("nextval('shared.global_seq'::regclass)"))?.defaultExpression
            == "nextval('shared.global_seq'::regclass)")
    }

    @Test("Arrays that do not pair, or cannot be read, give no qualified default")
    func unpairedArraysGiveNoDefault() {
        let expression = "nextval('sales.orders_id_seq'::regclass)"
        #expect(parsed(row(expression, qualified: "{sales.orders_id_seq}", relative: "{}"))?.defaultExpression == nil)
        #expect(parsed(row(expression, qualified: "{sales.orders_id_seq", relative: "{orders_id_seq}"))?
            .defaultExpression == nil)
        #expect(parsed(row(
            expression, qualified: "{sales.orders_id_seq}", relative: "{orders_id_seq}", standardConformingStrings: nil
        ))?.defaultExpression == nil)
    }

    @Test("A generated column still has no default, whatever the arrays say")
    func generatedColumnHasNoDefault() {
        let column = parsed(row("(a + 1)", generated: "s", qualified: "{sales.x}", relative: "{x}"))
        #expect(column?.defaultExpression == nil)
        #expect(column?.generationExpression == "(a + 1)")
    }

    @Test("The collation is carried as read, and an empty one is none")
    func collationIsCarried() {
        #expect(parsed(row(nil, collation: #"app."Case Insens""#))?.collation == #"app."Case Insens""#)
        #expect(parsed(row(nil, collation: #"pg_catalog."default""#))?.collation == #"pg_catalog."default""#)
        #expect(parsed(row(nil, collation: ""))?.collation == nil)
        #expect(parsed(row(nil))?.collation == nil)
    }
}

@Suite("PostgreSQL dependent sequences and the column DDL read")
struct PostgreSQLSequenceDependencyParityTests {
    @Test("Both read the column default's pg_depend rows, each with its own correlation")
    func bothStartFromTheColumnDefaultDependency() {
        let columnRead = PostgreSQLSchemaQueries.columnDDLQuery(
            schema: "sales", table: "orders", capabilities: PostgreSQLCapabilities(serverVersion: 170_000)
        )
        #expect(columnRead.contains(PostgreSQLSequenceQueries.columnDefaultDependency(alias: "dep")))
        #expect(columnRead.contains("AND dep.objid = ad.oid"))
        #expect(columnRead.contains("JOIN pg_catalog.pg_class seq ON seq.oid = dep.refobjid"))

        for source in [PostgreSQLSequenceQueries.Source.sequencesView, .sequenceParameters] {
            let listing = PostgreSQLSequenceQueries.sequenceList(schema: "sales", dependentOnTable: "orders", source: source)
            #expect(listing.contains(PostgreSQLSequenceQueries.columnDefaultDependency(alias: "d")), "\(source)")
            #expect(listing.contains("AND d.objid = ad.oid"), "\(source)")
            #expect(listing.contains("AND d.refobjid = c.oid"), "\(source)")
            #expect(listing.contains("WHERE t.relname = 'orders'"), "\(source)")
            #expect(listing.contains("AND tn.nspname = 'sales'"), "\(source)")
        }
    }

    @Test("Both keep to sequences in the table's own schema, which is where the copy creates them")
    func bothKeepToTheTablesSchema() {
        let columnRead = PostgreSQLSchemaQueries.columnDDLQuery(
            schema: "sales", table: "orders", capabilities: PostgreSQLCapabilities(serverVersion: 170_000)
        )
        #expect(columnRead.contains("AND seq.relnamespace = c.relnamespace"))
        #expect(columnRead.contains("AND seq.relkind = 'S'"))

        let view = PostgreSQLSequenceQueries.sequenceList(schema: "sales", dependentOnTable: "orders", source: .sequencesView)
        #expect(view.contains("FROM pg_catalog.pg_sequences s"))
        #expect(view.contains("WHERE s.schemaname = 'sales'"))

        let parameters = PostgreSQLSequenceQueries.sequenceList(
            schema: "sales", dependentOnTable: "orders", source: .sequenceParameters
        )
        #expect(parameters.contains("WHERE c.relkind = 'S'"))
        #expect(parameters.contains("AND n.nspname = 'sales'"))
    }

    @Test("The shared condition names the attribute default and relation catalogs only")
    func sharedConditionNamesBothCatalogs() {
        let condition = PostgreSQLSequenceQueries.columnDefaultDependency(alias: "x")
        #expect(condition.contains("x.classid = 'pg_catalog.pg_attrdef'::pg_catalog.regclass"))
        #expect(condition.contains("AND x.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass"))
        #expect(!condition.contains("objid"))
    }
}
