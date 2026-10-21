//
//  PostgreSQLTypeStatementsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLTypeStatementsTests {
    private static let modern = PostgreSQLCapabilities(serverVersion: 180_000)

    private func type(_ kind: PluginUserDefinedTypeKind, name: String = "t") -> PluginUserDefinedTypeInfo {
        PluginUserDefinedTypeInfo(name: name, kind: kind, schema: "app")
    }

    private func alter(
        _ kind: PluginUserDefinedTypeKind,
        _ change: PluginUserDefinedTypeChange,
        capabilities: PostgreSQLCapabilities = modern
    ) -> [String]? {
        PostgreSQLTypeStatements.alter(type: type(kind), schema: "app", change: change, capabilities: capabilities)
    }

    @Test("A domain renames and comments as a domain, every other kind as a type")
    func renameAndComment() {
        #expect(alter(.domain, .rename(to: "New Name")) == ["ALTER DOMAIN \"app\".\"t\" RENAME TO \"New Name\""])
        #expect(alter(.range, .rename(to: "r2")) == ["ALTER TYPE \"app\".\"t\" RENAME TO \"r2\""])
        #expect(alter(.enumeration, .setComment("it's")) == ["COMMENT ON TYPE \"app\".\"t\" IS 'it''s'"])
        #expect(alter(.domain, .setComment("a\\b")) == ["COMMENT ON DOMAIN \"app\".\"t\" IS E'a\\\\b'"])
    }

    @Test("An empty or blank comment removes it")
    func removeComment() {
        #expect(alter(.composite, .setComment(nil)) == ["COMMENT ON TYPE \"app\".\"t\" IS NULL"])
        #expect(alter(.composite, .setComment("  ")) == ["COMMENT ON TYPE \"app\".\"t\" IS NULL"])
    }

    @Test("Enum labels go through the existing builders, with their version gates")
    func enumLabels() {
        let after = PluginEnumLabelPlacement(anchor: "ok", placesBefore: false)
        #expect(alter(.enumeration, .addEnumLabel("glad", placement: after))
            == ["ALTER TYPE \"app\".\"t\" ADD VALUE IF NOT EXISTS 'glad' AFTER 'ok'"])
        #expect(alter(.enumeration, .renameEnumLabel(from: "ok", to: "fine"))
            == ["ALTER TYPE \"app\".\"t\" RENAME VALUE 'ok' TO 'fine'"])
        #expect(alter(.enumeration, .renameEnumLabel(from: "ok", to: "fine"),
                      capabilities: PostgreSQLCapabilities(serverVersion: 90_600)) == nil)
        #expect(alter(.enumeration, .addEnumLabel("x", placement: after),
                      capabilities: PostgreSQLCapabilities(serverVersion: 90_000)) == nil)
        #expect(alter(.domain, .addEnumLabel("x", placement: nil)) == nil)
    }

    @Test("A domain sets and drops its default and NOT NULL")
    func domainDefaultAndNotNull() {
        #expect(alter(.domain, .setDefault("0")) == ["ALTER DOMAIN \"app\".\"t\" SET DEFAULT 0"])
        #expect(alter(.domain, .setDefault(nil)) == ["ALTER DOMAIN \"app\".\"t\" DROP DEFAULT"])
        #expect(alter(.domain, .setDefault(" ")) == ["ALTER DOMAIN \"app\".\"t\" DROP DEFAULT"])
        #expect(alter(.domain, .setNotNull(true)) == ["ALTER DOMAIN \"app\".\"t\" SET NOT NULL"])
        #expect(alter(.domain, .setNotNull(false)) == ["ALTER DOMAIN \"app\".\"t\" DROP NOT NULL"])
        #expect(alter(.enumeration, .setNotNull(true)) == nil)
    }

    @Test("A check is added named or unnamed, validated or NOT VALID, then dropped and validated")
    func domainChecks() {
        let named = PluginUserDefinedTypeCheck(name: "positive", expression: "VALUE > 0")
        let unnamed = PluginUserDefinedTypeCheck(name: nil, expression: "VALUE < 100")
        #expect(alter(.domain, .addCheck(named, validatesExistingValues: true))
            == ["ALTER DOMAIN \"app\".\"t\" ADD CONSTRAINT \"positive\" CHECK (VALUE > 0)"])
        #expect(alter(.domain, .addCheck(unnamed, validatesExistingValues: false))
            == ["ALTER DOMAIN \"app\".\"t\" ADD CHECK (VALUE < 100) NOT VALID"])
        #expect(alter(.domain, .dropConstraint("positive")) == ["ALTER DOMAIN \"app\".\"t\" DROP CONSTRAINT \"positive\""])
        #expect(alter(.domain, .validateConstraint("positive"))
            == ["ALTER DOMAIN \"app\".\"t\" VALIDATE CONSTRAINT \"positive\""])
    }

    @Test("NOT VALID and VALIDATE need PostgreSQL 9.2")
    func domainValidationGate() {
        let old = PostgreSQLCapabilities(serverVersion: 90_100)
        let check = PluginUserDefinedTypeCheck(name: nil, expression: "VALUE > 0")
        #expect(alter(.domain, .addCheck(check, validatesExistingValues: false), capabilities: old) == nil)
        #expect(alter(.domain, .validateConstraint("c"), capabilities: old) == nil)
        #expect(alter(.domain, .addCheck(check, validatesExistingValues: true), capabilities: old) != nil)
    }

    @Test("A composite adds, drops, renames and retypes a field")
    func compositeFields() {
        #expect(alter(.composite, .addField(PluginUserDefinedTypeField(name: "zip code", type: "text")))
            == ["ALTER TYPE \"app\".\"t\" ADD ATTRIBUTE \"zip code\" text"])
        #expect(alter(.composite, .addField(PluginUserDefinedTypeField(name: "c", type: "text", collation: "\"C\"")))
            == ["ALTER TYPE \"app\".\"t\" ADD ATTRIBUTE \"c\" text COLLATE \"C\""])
        #expect(alter(.composite, .dropField("c")) == ["ALTER TYPE \"app\".\"t\" DROP ATTRIBUTE \"c\""])
        #expect(alter(.composite, .renameField(from: "a", to: "b"))
            == ["ALTER TYPE \"app\".\"t\" RENAME ATTRIBUTE \"a\" TO \"b\""])
        #expect(alter(.composite, .changeFieldType(field: "a", type: "bigint"))
            == ["ALTER TYPE \"app\".\"t\" ALTER ATTRIBUTE \"a\" SET DATA TYPE bigint"])
        #expect(alter(.composite, .dropField("a"), capabilities: PostgreSQLCapabilities(serverVersion: 90_000)) == nil)
        #expect(alter(.enumeration, .dropField("a")) == nil)
    }

    @Test("Only the four PostgreSQL kinds are altered")
    func foreignKinds() {
        #expect(alter(.aliasType, .rename(to: "x")) == nil)
        #expect(alter(.udt, .setComment("x")) == nil)
    }

    @Test("Create spells each kind and appends the comment")
    func create() {
        let enumeration = PluginUserDefinedTypeDefinition(
            name: "mood", schema: "app", kind: .enumeration, enumLabels: ["sad", "it's"], comment: "Feelings"
        )
        #expect(PostgreSQLTypeStatements.create(enumeration, schema: "app") == [
            "CREATE TYPE \"app\".\"mood\" AS ENUM (\n    'sad',\n    'it''s'\n)",
            "COMMENT ON TYPE \"app\".\"mood\" IS 'Feelings'"
        ])
        let composite = PluginUserDefinedTypeDefinition(
            name: "addr", schema: "app", kind: .composite,
            fields: [PluginUserDefinedTypeField(name: "street", type: "text"), PluginUserDefinedTypeField(name: "zip", type: "int")]
        )
        #expect(PostgreSQLTypeStatements.create(composite, schema: "app") == [
            "CREATE TYPE \"app\".\"addr\" AS (\n    \"street\" text,\n    \"zip\" int\n)"
        ])
        let domain = PluginUserDefinedTypeDefinition(
            name: "posint", schema: "app", kind: .domain, baseType: "integer", defaultValue: "1", isNotNull: true,
            checks: [
                PluginUserDefinedTypeCheck(name: "positive", expression: "VALUE > 0"),
                PluginUserDefinedTypeCheck(name: nil, expression: "VALUE < 100")
            ],
            comment: "Counts"
        )
        #expect(PostgreSQLTypeStatements.create(domain, schema: "app") == [
            "CREATE DOMAIN \"app\".\"posint\" AS integer\n    DEFAULT 1\n    NOT NULL\n"
                + "    CONSTRAINT \"positive\" CHECK (VALUE > 0)\n    CHECK (VALUE < 100)",
            "COMMENT ON DOMAIN \"app\".\"posint\" IS 'Counts'"
        ])
    }

    @Test("An empty enum or composite parses; a domain needs a base type; a range is not created here")
    func createEdges() {
        #expect(PostgreSQLTypeStatements.create(
            PluginUserDefinedTypeDefinition(name: "e", schema: "s", kind: .enumeration), schema: "s"
        ) == ["CREATE TYPE \"s\".\"e\" AS ENUM ()"])
        #expect(PostgreSQLTypeStatements.create(
            PluginUserDefinedTypeDefinition(name: "c", schema: "s", kind: .composite), schema: "s"
        ) == ["CREATE TYPE \"s\".\"c\" AS ()"])
        #expect(PostgreSQLTypeStatements.create(
            PluginUserDefinedTypeDefinition(name: "d", schema: "s", kind: .domain, baseType: " "), schema: "s"
        ) == nil)
        #expect(PostgreSQLTypeStatements.create(
            PluginUserDefinedTypeDefinition(name: "r", schema: "s", kind: .range, baseType: "int"), schema: "s"
        ) == nil)
    }

    /// Measured on PostgreSQL 11, 13 and 18: 11 answers "ALTER TYPE ... ADD cannot run inside a
    /// transaction block"; 13 and 18 add, place after and rename the new label inside one BEGIN.
    @Test("Only a label addition before PostgreSQL 12 runs outside a transaction")
    func transactionRule() {
        let add = PluginUserDefinedTypeChange.addEnumLabel("x", placement: nil)
        #expect(PostgreSQLTypeStatements.runsOutsideTransaction(add, capabilities: PostgreSQLCapabilities(serverVersion: 110_022)))
        #expect(!PostgreSQLTypeStatements.runsOutsideTransaction(add, capabilities: PostgreSQLCapabilities(serverVersion: 120_000)))
        #expect(!PostgreSQLTypeStatements.runsOutsideTransaction(
            .renameEnumLabel(from: "a", to: "b"), capabilities: PostgreSQLCapabilities(serverVersion: 110_022)
        ))
    }

    @Test("Drop appends CASCADE only when asked")
    func drop() {
        #expect(PostgreSQLTypeStatements.drop(schema: "app", name: "t", kind: .domain, cascade: true)
            == "DROP DOMAIN \"app\".\"t\" CASCADE")
        #expect(PostgreSQLTypeStatements.drop(schema: "app", name: "t", kind: .enumeration, cascade: false)
            == "DROP TYPE \"app\".\"t\"")
    }
}
