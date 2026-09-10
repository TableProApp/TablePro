//
//  PostgreSQLTypeQueryTests.swift
//  TableProTests
//
//  The catalog SQL that lists user-defined types and the statements that edit an enum.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("PostgreSQL type catalog queries")
struct PostgreSQLTypeQueryTests {
    @Test("The listing reads pg_type for enums, composites, domains and ranges in one schema")
    func listReadsPgType() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 170_000)
        #expect(sql.contains("FROM pg_catalog.pg_type t"))
        #expect(sql.contains("t.typtype IN ('e', 'c', 'd', 'r')"))
        #expect(sql.contains("AND n.nspname = 'app'"))
        #expect(!sql.contains("information_schema"))
    }

    /// Every table owns a composite type of its own row shape, and an extension's types belong to
    /// the extension. Neither is a type the user created.
    @Test("Table row types and extension members are excluded")
    func excludesRowTypesAndExtensionMembers() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 170_000)
        #expect(sql.contains("(t.typtype <> 'c' OR c.relkind = 'c')"))
        #expect(sql.contains("d.deptype = 'e'"))
    }

    /// PostgreSQL 17 files a domain's NOT NULL as a constraint row; emitting it beside NOT NULL
    /// would state the same thing twice in the definition.
    @Test("Only CHECK constraints are collected for a domain")
    func domainConstraintsAreChecksOnly() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 170_000)
        #expect(sql.contains("con.contype = 'c'"))
    }

    @Test("The projection matches the parser's column order")
    func projectionOrderMatchesParser() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 170_000)
        let aliases = [
            "AS identity", "AS name", "AS schema", "AS kind", "AS owner", "AS comment", "AS enum_labels",
            "AS fields", "AS base_type", "AS collation", "AS not_null", "AS default_value", "AS constraints",
            "AS range_subtype", "AS range_canonical", "AS range_subtype_diff", "AS range_opclass",
            "AS range_collation", "AS range_multirange", "AS spelling"
        ]
        #expect(aliases.count == PostgreSQLTypeDefinition.Column.allCases.count)
        var searchStart = sql.startIndex
        for alias in aliases {
            let range = sql.range(of: alias, range: searchStart..<sql.endIndex)
            #expect(range != nil, "\(alias) missing or out of order")
            guard let range else { return }
            searchStart = range.upperBound
        }
    }

    /// A type keeps its oid when it is moved to another schema, so a reload by oid carries no
    /// schema predicate at all.
    @Test("A reload addresses one oid and nothing else")
    func identityPredicate() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: nil, identity: "16387", serverVersionNumber: 170_000
        )
        #expect(sql.contains("AND t.oid = 16387::oid"))
        #expect(!sql.contains("n.nspname ="))
    }

    @Test("A listing escapes the schema literal")
    func schemaLiteral() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: "o'brien", identity: nil, serverVersionNumber: 170_000
        )
        #expect(sql.contains("AND n.nspname = 'o''brien'"))
        #expect(!sql.contains("AND t.oid = "))
    }

    /// The picker writes this spelling into a column definition as it stands, so the server, which
    /// knows its own reserved words and folding, is what quotes it.
    @Test("The listing carries the server's own quoted, qualified spelling of each type")
    func listingCarriesSpelling() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 170_000)
        #expect(sql.contains("pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(t.typname) AS spelling"))
    }

    @Test("A server before 14 has no multirange to report")
    func legacyServerSkipsMultirange() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 130_000)
        #expect(sql.contains("NULL::text AS range_multirange"))
        #expect(!sql.contains("rngmultitypid"))
        let modern = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 140_000)
        #expect(modern.contains("rngmultitypid"))
    }

    /// The identity is an oid the driver handed out, so anything that is not one is a caller error
    /// and never reaches the statement, quoted or otherwise.
    @Test("A non-numeric identity is ignored rather than interpolated")
    func nonNumericIdentityIsIgnored() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: "app", identity: "1 OR 1=1", serverVersionNumber: 170_000
        )
        #expect(!sql.contains("AND t.oid = "))
        #expect(!sql.contains("OR 1=1"))
    }

    /// With `standard_conforming_strings` off, a backslash before a doubled quote would let the
    /// literal close early. An E-string reads the backslash as an escape on every server, so a
    /// value carrying one is written that way, and one without keeps the plain spelling.
    @Test("A literal with a backslash is written as an E-string, one without stays plain")
    func backslashLiteralsUseEscapeStrings() {
        #expect(PostgreSQLObjectQueries.quoteLiteral("plain") == "'plain'")
        #expect(PostgreSQLObjectQueries.quoteLiteral("it's") == "'it''s'")
        #expect(PostgreSQLObjectQueries.quoteLiteral("back\\slash") == "E'back\\\\slash'")
        #expect(PostgreSQLObjectQueries.quoteLiteral("\\'; DROP TYPE x; --") == "E'\\\\''; DROP TYPE x; --'")

        let sql = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: "a\\'b", identity: nil, serverVersionNumber: 170_000
        )
        #expect(sql.contains("AND n.nspname = E'a\\\\''b'"))
        #expect(
            PostgreSQLObjectQueries.addEnumLabel(
                schema: "app", name: "mood", label: "a\\b", placement: nil, ifNotExists: false
            ) == "ALTER TYPE \"app\".\"mood\" ADD VALUE E'a\\\\b'"
        )
    }

    @Test("A server before 9.2 has no pg_range and lists no ranges")
    func legacyServerSkipsRanges() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 90_100)
        #expect(!sql.contains("pg_range"))
        #expect(sql.contains("t.typtype IN ('e', 'c', 'd')"))
        #expect(sql.contains("NULL::text AS range_subtype"))
    }

    @Test("A server before 9.4 has no json_build_object and reports no fields or constraints")
    func legacyServerSkipsJsonObjects() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 90_300)
        #expect(!sql.contains("json_build_object"))
        #expect(sql.contains("NULL::text AS fields"))
    }

    /// libpq answers 0 for a handle it has not connected, and reading that as ancient would emit
    /// the legacy projection on every current server.
    @Test("An unknown server version reads as modern")
    func unknownVersionIsModern() {
        let sql = PostgreSQLObjectQueries.userDefinedTypeList(schema: "app", identity: nil, serverVersionNumber: 0)
        #expect(sql.contains("pg_range"))
        #expect(sql.contains("json_build_object"))
    }

    @Test("Adding a label appends by default and places beside a neighbour when asked")
    func addEnumLabel() {
        #expect(
            PostgreSQLObjectQueries.addEnumLabel(
                schema: "app", name: "mood", label: "meh", placement: nil, ifNotExists: false
            ) == "ALTER TYPE \"app\".\"mood\" ADD VALUE 'meh'"
        )
        #expect(
            PostgreSQLObjectQueries.addEnumLabel(
                schema: "app", name: "mood", label: "meh",
                placement: PluginEnumLabelPlacement(anchor: "ok", placesBefore: true), ifNotExists: false
            ) == "ALTER TYPE \"app\".\"mood\" ADD VALUE 'meh' BEFORE 'ok'"
        )
        #expect(
            PostgreSQLObjectQueries.addEnumLabel(
                schema: "app", name: "mood", label: "meh",
                placement: PluginEnumLabelPlacement(anchor: "ok", placesBefore: false), ifNotExists: false
            ) == "ALTER TYPE \"app\".\"mood\" ADD VALUE 'meh' AFTER 'ok'"
        )
    }

    /// The driver resends a statement once after a lost connection. A label that landed before the
    /// reply was lost must not fail the resend, so an add is written to be idempotent wherever the
    /// server allows it.
    @Test("Adding a label is idempotent from 9.3 on")
    func addEnumLabelIfNotExists() {
        #expect(
            PostgreSQLObjectQueries.addEnumLabel(
                schema: "app", name: "mood", label: "meh",
                placement: PluginEnumLabelPlacement(anchor: "ok", placesBefore: false), ifNotExists: true
            ) == "ALTER TYPE \"app\".\"mood\" ADD VALUE IF NOT EXISTS 'meh' AFTER 'ok'"
        )
        #expect(!PostgreSQLCapabilities(serverVersion: 90_200).hasEnumAddValueIfNotExists)
        #expect(PostgreSQLCapabilities(serverVersion: 90_300).hasEnumAddValueIfNotExists)
    }

    @Test("A label with a quote is escaped as a literal, and a type name as an identifier")
    func enumLabelQuoting() {
        let sql = PostgreSQLObjectQueries.addEnumLabel(
            schema: "app", name: "Weird \"Name\"", label: "it's", placement: nil, ifNotExists: false
        )
        #expect(sql == "ALTER TYPE \"app\".\"Weird \"\"Name\"\"\" ADD VALUE 'it''s'")
    }

    @Test("Renaming a label spells RENAME VALUE with both literals")
    func renameEnumLabel() {
        let sql = PostgreSQLObjectQueries.renameEnumLabel(schema: "app", name: "mood", from: "ok", to: "fine")
        #expect(sql == "ALTER TYPE \"app\".\"mood\" RENAME VALUE 'ok' TO 'fine'")
    }

    @Test("Rename needs PostgreSQL 10; placement needs 9.1")
    func versionGates() {
        #expect(!PostgreSQLCapabilities(serverVersion: 90_600).hasRenameEnumValue)
        #expect(PostgreSQLCapabilities(serverVersion: 100_000).hasRenameEnumValue)
        #expect(!PostgreSQLCapabilities(serverVersion: 90_000).hasEnumLabelPlacement)
        #expect(PostgreSQLCapabilities(serverVersion: 90_100).hasEnumLabelPlacement)
        #expect(PostgreSQLCapabilities.assumingModernWhenUnknown(0).hasRenameEnumValue)
    }

    @Test("The template creates an enum in the schema it was asked for")
    func createTemplate() {
        let template = PostgreSQLObjectQueries.createTypeTemplate(schema: "sales")
        #expect(template.hasPrefix("CREATE TYPE \"sales\".\"type_name\" AS ENUM ("))
        #expect(template.hasSuffix(");"))
    }
}
