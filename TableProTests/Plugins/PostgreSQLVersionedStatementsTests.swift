//
//  PostgreSQLVersionedStatementsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLVersionedStatements")
struct PostgreSQLVersionedStatementsTests {
    private static let v91 = PostgreSQLCapabilities(serverVersion: 90_124)
    private static let v92 = PostgreSQLCapabilities(serverVersion: 90_223)
    private static let v96 = PostgreSQLCapabilities(serverVersion: 90_600)
    private static let v10 = PostgreSQLCapabilities(serverVersion: 100_000)
    private static let v11 = PostgreSQLCapabilities(serverVersion: 110_000)
    private static let v12 = PostgreSQLCapabilities(serverVersion: 120_000)
    private static let v13 = PostgreSQLCapabilities(serverVersion: 130_000)
    private static let v14 = PostgreSQLCapabilities(serverVersion: 140_000)
    private static let v15 = PostgreSQLCapabilities(serverVersion: 150_000)
    private static let v16 = PostgreSQLCapabilities(serverVersion: 160_000)
    private static let v17 = PostgreSQLCapabilities(serverVersion: 170_000)

    @Test("DDL thresholds match the versions measured against live servers")
    func thresholds() {
        #expect(!Self.v91.hasRenameConstraint)
        #expect(Self.v92.hasRenameConstraint)
        #expect(!Self.v92.hasCreateSchemaIfNotExists)
        #expect(PostgreSQLCapabilities(serverVersion: 90_300).hasCreateSchemaIfNotExists)
        #expect(!PostgreSQLCapabilities(serverVersion: 90_426).hasBrinIndexes)
        #expect(PostgreSQLCapabilities(serverVersion: 90_500).hasBrinIndexes)
        #expect(!Self.v10.hasExecuteFunctionTriggerSyntax)
        #expect(Self.v11.hasExecuteFunctionTriggerSyntax)
        #expect(!Self.v11.hasReindexConcurrently)
        #expect(Self.v12.hasReindexConcurrently)
        #expect(!Self.v13.hasCreateOrReplaceTrigger)
        #expect(Self.v14.hasCreateOrReplaceTrigger)
        #expect(!Self.v15.hasUnnamedReindexDatabase)
        #expect(Self.v16.hasUnnamedReindexDatabase)
    }

    @Test("An unknown version takes the conservative form of every gated statement")
    func unknownVersionIsConservative() {
        let unknown = PostgreSQLCapabilities(serverVersion: 0)
        #expect(!unknown.hasBypassRLS)
        #expect(!unknown.hasIdentityColumns)
        #expect(!unknown.hasGeneratedColumns)
        #expect(!unknown.hasSetGeneratedExpression)
        #expect(!unknown.hasVirtualGeneratedColumns)
        #expect(!unknown.hasDatabaseICULocale)
        #expect(!unknown.hasModernICUSyntax)
        #expect(PostgreSQLVersionedStatements.createSchema("s", capabilities: unknown).hasPrefix("DO "))
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: "app", capabilities: unknown)
            == "REINDEX DATABASE \"app\"")
        let template = PostgreSQLVersionedStatements.triggerTemplate(
            qualifiedTable: "t", qualifiedFunction: "f", capabilities: unknown
        )
        #expect(template.contains("\nCREATE TRIGGER \"trigger_name\""))
        #expect(template.contains("EXECUTE PROCEDURE f();"))
        #expect(PostgreSQLVersionedStatements.copyRows(into: "t", from: "s", columnList: "a", capabilities: unknown)
            == "INSERT INTO t (a) SELECT a FROM s")
        #expect(!PostgreSQLVersionedStatements.roleAttributes(capabilities: unknown).contains(.bypassrls))
    }

    @Test("The session probe row parses into a database and a version")
    func sessionFactsParsing() {
        let facts = PostgreSQLSessionFacts(probeRow: ["app", "90124"])
        #expect(facts == PostgreSQLSessionFacts(database: "app", serverVersion: 90_124))
        #expect(PostgreSQLSessionFacts(probeRow: ["app", " 170011 "]).serverVersion == 170_011)
        #expect(PostgreSQLSessionFacts(probeRow: ["", "0"]) == .unknown)
        #expect(PostgreSQLSessionFacts(probeRow: [nil, "9.1.24"]) == .unknown)
        #expect(PostgreSQLSessionFacts(probeRow: []) == .unknown)
    }

    @Test("libpq's own version wins; the probed one fills in only when libpq reports none")
    func resolvedServerVersion() {
        let facts = PostgreSQLSessionFacts(database: "app", serverVersion: 90_124)
        #expect(facts.resolvedServerVersion(reported: 170_011) == 170_011)
        #expect(facts.resolvedServerVersion(reported: 0) == 90_124)
        #expect(PostgreSQLSessionFacts.unknown.resolvedServerVersion(reported: 0) == 0)
    }

    @Test("9.3 and later create a schema with IF NOT EXISTS")
    func createSchemaModern() {
        let statement = PostgreSQLVersionedStatements.createSchema("sales", capabilities: Self.v96)
        #expect(statement == "CREATE SCHEMA IF NOT EXISTS \"sales\"")
    }

    @Test("Before 9.3 a schema is created from a DO block guarded by pg_namespace")
    func createSchemaLegacy() {
        let statement = PostgreSQLVersionedStatements.createSchema("sales", capabilities: Self.v91)
        #expect(statement.hasPrefix("DO $tablepro$ "))
        #expect(statement.hasSuffix(" $tablepro$"))
        #expect(statement.contains("WHERE nspname = 'sales'"))
        #expect(statement.contains("EXECUTE 'CREATE SCHEMA \"sales\"'"))
        #expect(!statement.contains("IF NOT EXISTS \""))
    }

    @Test("A legacy schema name with quotes and backslashes stays inside its literals")
    func createSchemaLegacyEscapesName() {
        let statement = PostgreSQLVersionedStatements.createSchema(#"o'b\"x"#, capabilities: Self.v91)
        #expect(statement.contains(#"nspname = E'o''b\\"x'"#))
        #expect(statement.contains(#"EXECUTE E'CREATE SCHEMA "o''b\\""x"'"#))
    }

    @Test("A name that contains the dollar-quote tag gets a tag it cannot close")
    func createSchemaLegacyAvoidsTagCollision() {
        let statement = PostgreSQLVersionedStatements.createSchema("x$tablepro$y", capabilities: Self.v91)
        #expect(statement.hasPrefix("DO $tablepro_$ "))
        #expect(statement.hasSuffix(" $tablepro_$"))
    }

    @Test("REINDEX DATABASE names the current database where the server requires it")
    func reindexDatabase() {
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: "app", capabilities: Self.v91)
            == "REINDEX DATABASE \"app\"")
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: "app", capabilities: Self.v11)
            == "REINDEX DATABASE \"app\"")
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: "app", capabilities: Self.v12)
            == "REINDEX DATABASE CONCURRENTLY \"app\"")
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: "app", capabilities: Self.v15)
            == "REINDEX DATABASE CONCURRENTLY \"app\"")
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: "app", capabilities: Self.v16)
            == "REINDEX DATABASE CONCURRENTLY")
    }

    @Test("Without a known database a pre-16 server gets no REINDEX DATABASE at all")
    func reindexDatabaseWithoutName() {
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: nil, capabilities: Self.v12) == nil)
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: "", capabilities: Self.v91) == nil)
        #expect(PostgreSQLVersionedStatements.reindexDatabase(currentDatabase: nil, capabilities: Self.v17)
            == "REINDEX DATABASE CONCURRENTLY")
    }

    @Test("The new-trigger template uses the syntax each server accepts")
    func triggerTemplate() {
        func template(_ capabilities: PostgreSQLCapabilities) -> String {
            PostgreSQLVersionedStatements.triggerTemplate(
                qualifiedTable: "\"public\".\"t\"",
                qualifiedFunction: "\"public\".\"trigger_function\"",
                capabilities: capabilities
            )
        }
        let legacy = template(Self.v91)
        #expect(legacy.contains("\nCREATE TRIGGER \"trigger_name\""))
        #expect(legacy.contains("EXECUTE PROCEDURE \"public\".\"trigger_function\"();"))
        #expect(!legacy.contains("OR REPLACE TRIGGER"))
        #expect(!legacy.contains("DROP TRIGGER"))

        let eleven = template(Self.v11)
        #expect(eleven.contains("EXECUTE FUNCTION"))
        #expect(!eleven.contains("DROP TRIGGER"))

        let thirteen = template(Self.v13)
        #expect(!thirteen.contains("OR REPLACE TRIGGER"))

        let modern = template(Self.v14)
        #expect(modern.contains("CREATE OR REPLACE TRIGGER \"trigger_name\""))
        #expect(modern.contains("EXECUTE FUNCTION"))
        #expect(!modern.contains("DROP TRIGGER"))
        #expect(modern.hasPrefix("CREATE OR REPLACE FUNCTION \"public\".\"trigger_function\"()"))
    }

    @Test("Before 14 an edited trigger keeps its plain CREATE TRIGGER, since the app drops it first")
    func editableTriggerLegacy() {
        let definition = PostgreSQLVersionedStatements.editableTriggerDefinition(
            functionDefinition: "CREATE OR REPLACE FUNCTION f() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$",
            triggerDefinition: "CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW EXECUTE PROCEDURE f()",
            dropStatement: "DROP TRIGGER IF EXISTS \"t\" ON \"public\".\"x\"",
            capabilities: Self.v13
        )
        #expect(definition.hasSuffix("\n\nCREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW EXECUTE PROCEDURE f();"))
        #expect(!definition.contains("OR REPLACE TRIGGER"))
        #expect(!definition.contains("DROP TRIGGER"))
    }

    @Test("From 14 an edited trigger is replaced in place")
    func editableTriggerModern() {
        let definition = PostgreSQLVersionedStatements.editableTriggerDefinition(
            functionDefinition: "CREATE OR REPLACE FUNCTION f()",
            triggerDefinition: "CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW EXECUTE FUNCTION f()",
            dropStatement: "DROP TRIGGER IF EXISTS \"t\" ON \"public\".\"x\"",
            capabilities: Self.v14
        )
        #expect(definition == "CREATE OR REPLACE FUNCTION f();\n\nCREATE OR REPLACE TRIGGER t BEFORE INSERT ON x FOR EACH ROW EXECUTE FUNCTION f();")
    }

    @Test("A constraint trigger has no OR REPLACE form, so it is dropped and recreated")
    func editableConstraintTrigger() {
        let definition = PostgreSQLVersionedStatements.editableTriggerDefinition(
            functionDefinition: "CREATE OR REPLACE FUNCTION f()",
            triggerDefinition: "CREATE CONSTRAINT TRIGGER t AFTER INSERT ON x FOR EACH ROW EXECUTE FUNCTION f()",
            dropStatement: "DROP TRIGGER IF EXISTS \"t\" ON \"public\".\"x\"",
            capabilities: Self.v17
        )
        #expect(definition.contains("DROP TRIGGER IF EXISTS \"t\" ON \"public\".\"x\";\nCREATE CONSTRAINT TRIGGER t"))
    }

    @Test("RENAME CONSTRAINT exists from 9.2; on 9.1 the rename falls back to drop and re-add")
    func renameConstraint() {
        #expect(PostgreSQLVersionedStatements.renameConstraint(
            qualifiedTable: "\"public\".\"t\"", from: "a", to: "b", capabilities: Self.v91
        ) == nil)
        #expect(PostgreSQLVersionedStatements.renameConstraint(
            qualifiedTable: "\"public\".\"t\"", from: "a", to: "b", capabilities: Self.v92
        ) == "ALTER TABLE \"public\".\"t\" RENAME CONSTRAINT \"a\" TO \"b\"")
        #expect(PostgreSQLVersionedStatements.renameConstraint(
            qualifiedTable: "\"public\".\"t\"", from: "", to: "b", capabilities: Self.v17
        ) == nil)
    }

    @Test("The column reorder copy carries OVERRIDING SYSTEM VALUE only where identity columns exist")
    func copyRows() {
        let legacy = PostgreSQLVersionedStatements.copyRows(
            into: "\"public\".\"t\"", from: "\"public\".\"t_old\"", columnList: "\"a\", \"b\"", capabilities: Self.v96
        )
        #expect(legacy == "INSERT INTO \"public\".\"t\" (\"a\", \"b\") SELECT \"a\", \"b\" FROM \"public\".\"t_old\"")
        let modern = PostgreSQLVersionedStatements.copyRows(
            into: "\"public\".\"t\"", from: "\"public\".\"t_old\"", columnList: "\"a\"", capabilities: Self.v10
        )
        #expect(modern == "INSERT INTO \"public\".\"t\" (\"a\") OVERRIDING SYSTEM VALUE SELECT \"a\" FROM \"public\".\"t_old\"")
    }

    @Test("A generated column is refused before 12 with the version it needs")
    func generatedColumnRefusal() {
        let plain = PluginColumnDefinition(name: "a", dataType: "int", generationExpression: nil, generationKind: nil)
        let generated = PluginColumnDefinition(
            name: "b", dataType: "int", generationExpression: "a * 2", generationKind: .stored
        )
        let blankExpression = PluginColumnDefinition(
            name: "c", dataType: "int", generationExpression: "", generationKind: nil
        )
        #expect(PostgreSQLVersionedStatements.refusal(for: .addColumn(plain), capabilities: Self.v91) == nil)
        #expect(PostgreSQLVersionedStatements.refusal(for: .addColumn(blankExpression), capabilities: Self.v91) == nil)
        let reason = PostgreSQLVersionedStatements.refusal(for: .addColumn(generated), capabilities: Self.v11)
        #expect(reason?.contains("b") == true)
        #expect(reason?.contains("PostgreSQL 12 or later") == true)
        #expect(PostgreSQLVersionedStatements.refusal(for: .addColumn(generated), capabilities: Self.v12) == nil)
    }

    @Test("BRIN is refused before 9.5; FULLTEXT and SPATIAL are refused on every version")
    func indexRefusal() {
        func index(_ type: String?) -> PluginIndexDefinition {
            PluginIndexDefinition(name: "ix", columns: ["a"], indexType: type)
        }
        let brinOld = PostgreSQLVersionedStatements.refusal(
            for: .addIndex(index("brin")), capabilities: PostgreSQLCapabilities(serverVersion: 90_426)
        )
        #expect(brinOld?.contains("9.5 or later") == true)
        #expect(PostgreSQLVersionedStatements.refusal(
            for: .addIndex(index("BRIN")), capabilities: PostgreSQLCapabilities(serverVersion: 90_500)
        ) == nil)
        for type in ["FULLTEXT", "spatial"] {
            let reason = PostgreSQLVersionedStatements.refusal(for: .addIndex(index(type)), capabilities: Self.v17)
            #expect(reason?.contains(type.uppercased()) == true)
        }
        for type in [nil, "", "BTREE", "HASH", "GIN", "GIST"] {
            #expect(PostgreSQLVersionedStatements.refusal(for: .addIndex(index(type)), capabilities: Self.v91) == nil)
        }
    }

    @Test("Renaming a check constraint is refused on 9.1 only")
    func renameRefusal() {
        let rename = PluginSchemaOperation.renameCheckConstraint(from: "a", to: "b")
        #expect(PostgreSQLVersionedStatements.refusal(for: rename, capabilities: Self.v91)?.contains("9.2 or later") == true)
        #expect(PostgreSQLVersionedStatements.refusal(for: rename, capabilities: Self.v92) == nil)
    }

    @Test("A table definition is refused by its first refused column or index")
    func createTableRefusal() {
        let definition = PluginCreateTableDefinition(
            tableName: "t",
            columns: [PluginColumnDefinition(name: "a", dataType: "int", generationExpression: nil, generationKind: nil)],
            indexes: [PluginIndexDefinition(name: "ix", columns: ["a"], indexType: "BRIN")]
        )
        #expect(PostgreSQLVersionedStatements.refusal(
            for: definition, capabilities: PostgreSQLCapabilities(serverVersion: 90_426)
        )?.contains("BRIN") == true)
        #expect(PostgreSQLVersionedStatements.refusal(for: definition, capabilities: Self.v96) == nil)
    }

    @Test("The structure editor hides generated fields before 12, BRIN before 9.5 and MySQL index types always")
    func unsupportedStructureOptions() {
        #expect(PostgreSQLVersionedStatements.unsupportedStructureColumnFields(capabilities: Self.v11)
            == [.generated, .generationExpression])
        #expect(PostgreSQLVersionedStatements.unsupportedStructureColumnFields(capabilities: Self.v12).isEmpty)
        #expect(PostgreSQLVersionedStatements.unsupportedIndexTypes(capabilities: Self.v91) == ["BRIN", "FULLTEXT", "SPATIAL"])
        #expect(PostgreSQLVersionedStatements.unsupportedIndexTypes(capabilities: Self.v96) == ["FULLTEXT", "SPATIAL"])
    }

    @Test("BYPASSRLS is a role attribute only from 9.5")
    func roleAttributes() {
        let legacy = PostgreSQLVersionedStatements.roleAttributes(capabilities: Self.v91)
        #expect(!legacy.contains(.bypassrls))
        #expect(legacy.contains(.replication))
        #expect(legacy.count == PostgreSQLRoleAttribute.allCases.count - 1)
        #expect(PostgreSQLVersionedStatements.roleAttributes(capabilities: Self.v96) == Set(PostgreSQLRoleAttribute.allCases))
    }
}
