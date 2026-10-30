//
//  ObjectCopyEligibilityTests.swift
//  TableProTests
//
//  Every refusal a copy can make before it opens a driver.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ObjectCopyEligibilityTests {
    private func endpoint(
        _ database: String,
        type: DatabaseType = .mysql,
        schema: String? = nil,
        safeMode: SafeModeLevel = .silent,
        connectionId: UUID = UUID()
    ) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: database, schema: schema),
            connectionName: "server",
            databaseType: type,
            safeModeLevel: safeMode,
            color: .blue
        )
    }

    @Test
    func aReadOnlyTargetIsRefused() {
        #expect(ObjectCopyEligibility.targetRefusal(endpoint("app", safeMode: .readOnly)) != nil)
        #expect(ObjectCopyEligibility.targetRefusal(endpoint("app")) == nil)
    }

    /// A copy stays inside SQL and may cross engines within it. The types are translated before
    /// the target driver writes any DDL, so the refusal that is left is the one nothing can
    /// translate: an engine whose query language is not SQL parses neither `CREATE TABLE` nor
    /// `INSERT … VALUES`.
    @Test
    func aCopyCrossesEnginesButNotLanguages() {
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .mysql, to: .postgresql, sourceLanguage: .sql, targetLanguage: .sql
        ) == nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .mssql, to: .mysql, sourceLanguage: .sql, targetLanguage: .sql
        ) == nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .mysql, to: .mariadb, sourceLanguage: .sql, targetLanguage: .sql
        ) == nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .mysql, to: .mongodb, sourceLanguage: .sql, targetLanguage: .javascript
        ) != nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .mongodb, to: .mysql, sourceLanguage: .javascript, targetLanguage: .sql
        ) != nil)
    }

    /// DynamoDB declares `.sql` for PartiQL and Cassandra for CQL, so the editor language alone
    /// let a MySQL to DynamoDB copy through to a planner that could only fail. A crossing needs a
    /// type system the translator knows on both sides.
    @Test
    func aCrossingNeedsATypeSystemOnBothSides() {
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .mysql, to: .dynamodb, sourceLanguage: .sql, targetLanguage: .sql
        ) != nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .cassandra, to: .postgresql, sourceLanguage: .sql, targetLanguage: .sql
        ) != nil)
    }

    /// Nothing is translated within one engine, so an engine no family names still copies to
    /// itself. That is the path every registry-only driver already used.
    @Test
    func anEngineWithNoNamedFamilyStillCopiesToItself() {
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .dynamodb, to: .dynamodb, sourceLanguage: .sql, targetLanguage: .sql
        ) == nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .cassandra, to: .cassandra, sourceLanguage: .sql, targetLanguage: .sql
        ) == nil)
    }

    /// A view, routine or trigger is its definition, and the definition is the source engine's own
    /// SQL text. Nothing here parses it, so it cannot cross even where the tables beside it can.
    @Test
    func aDefinitionDoesNotCrossEngines() {
        #expect(ObjectCopyEligibility.definitionEngineRefusal(from: .mysql, to: .postgresql) != nil)
        #expect(ObjectCopyEligibility.definitionEngineRefusal(from: .mysql, to: .mariadb) == nil)
        #expect(ObjectCopyEligibility.definitionEngineRefusal(from: .postgresql, to: .postgresql) == nil)
    }

    private static let oracleModeSession = PluginSessionLexicalState(
        determined: [.plsqlBlocks, .alternativeQuoting], enabled: [.plsqlBlocks, .alternativeQuoting]
    )
    private static let pgModeSession = PluginSessionLexicalState(determined: [.plsqlBlocks], enabled: [])

    @Test
    func kingbaseESCopiesWithPostgreSQLOnlyInPostgreSQLMode() {
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .postgresql, to: .kingbasees, sourceLanguage: .sql, targetLanguage: .sql,
            sourceSession: nil, targetSession: Self.pgModeSession
        ) == nil)
        #expect(ObjectCopyEligibility.definitionEngineRefusal(
            from: .kingbasees, to: .postgresql, sourceSession: Self.pgModeSession, targetSession: nil
        ) == nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .postgresql, to: .kingbasees, sourceLanguage: .sql, targetLanguage: .sql,
            sourceSession: nil, targetSession: Self.oracleModeSession
        ) != nil)
        #expect(ObjectCopyEligibility.definitionEngineRefusal(
            from: .kingbasees, to: .postgresql, sourceSession: Self.oracleModeSession, targetSession: nil
        ) != nil)
    }

    @Test
    func kingbaseESCopiesBetweenServersOfTheSameModeOnly() {
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .kingbasees, to: .kingbasees, sourceLanguage: .sql, targetLanguage: .sql,
            sourceSession: Self.oracleModeSession, targetSession: Self.oracleModeSession
        ) == nil)
        #expect(ObjectCopyEligibility.engineRefusal(
            from: .kingbasees, to: .kingbasees, sourceLanguage: .sql, targetLanguage: .sql,
            sourceSession: Self.oracleModeSession, targetSession: Self.pgModeSession
        ) != nil)
    }

    /// Copying a database onto itself either drops the rows it is about to read or doubles them.
    @Test
    func theSameScopeIsRefusedAsATarget() {
        let connectionId = UUID()
        let source = endpoint("app", connectionId: connectionId)
        let same = endpoint("app", connectionId: connectionId)
        let other = endpoint("app_copy", connectionId: connectionId)

        #expect(ObjectCopyEligibility.sameObjectRefusal(source: source, target: same) != nil)
        #expect(ObjectCopyEligibility.sameObjectRefusal(source: source, target: other) == nil)
    }

    /// Two databases on one server are a valid pair, which is the case the endpoint type exists for.
    @Test
    func twoDatabasesOnOneConnectionAreAValidPair() {
        let connectionId = UUID()
        #expect(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("prod", connectionId: connectionId),
            target: endpoint("staging", connectionId: connectionId)
        ) == nil)
    }

    /// Right-clicking a PostgreSQL database gives a source with no schema, and choosing that same
    /// database's `public` as the target used to pass every refusal because the two endpoint ids
    /// differ. The planner then resolved both sides to `public` and dropped each table before
    /// streaming from the table it had just emptied.
    @Test
    func aScopedTargetInsideAnUnscopedSourceIsRefused() {
        let connectionId = UUID()
        let wholeDatabase = endpoint("app", type: .postgresql, connectionId: connectionId)
        let oneSchema = endpoint("app", type: .postgresql, schema: "public", connectionId: connectionId)

        #expect(ObjectCopyEligibility.sameObjectRefusal(source: wholeDatabase, target: oneSchema) != nil)
        #expect(ObjectCopyEligibility.sameObjectRefusal(source: oneSchema, target: wholeDatabase) != nil)
    }

    @Test
    func theSameSchemaIsRefusedWhateverItsCase() {
        let connectionId = UUID()
        #expect(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "Sales", connectionId: connectionId),
            target: endpoint("app", type: .postgresql, schema: "sales", connectionId: connectionId)
        ) != nil)
    }

    /// The case the refusal must not swallow: two schemas of one database are a valid pair, and
    /// copying between them is the whole point of a schema-scoped endpoint.
    @Test
    func twoSchemasOfOneDatabaseAreAValidPair() {
        let connectionId = UUID()
        #expect(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "sales", connectionId: connectionId),
            target: endpoint("app", type: .postgresql, schema: "archive", connectionId: connectionId)
        ) == nil)
        #expect(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "public", connectionId: connectionId),
            target: endpoint("app_copy", type: .postgresql, schema: "public", connectionId: connectionId)
        ) == nil)
    }

    /// An empty schema is how a scope with none is spelled, so it has to read as absent rather than
    /// as a schema literally named "".
    @Test
    func anEmptySchemaCountsAsNoSchema() {
        let connectionId = UUID()
        #expect(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "", connectionId: connectionId),
            target: endpoint("app", type: .postgresql, schema: "public", connectionId: connectionId)
        ) != nil)
    }

    @Test
    func onlySQLEnginesCanCopy() {
        #expect(ObjectCopyEligibility.supportsCopying(editorLanguage: .sql))
        #expect(!ObjectCopyEligibility.supportsCopying(editorLanguage: .javascript))
        #expect(!(ObjectCopyEligibility.supportsCopying(editorLanguage: .custom("mql"))))
    }

    @Test
    func duplicateIsOnlyOfferedWhereDatabasesExistAndCanBeWritten() {
        #expect(ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .sql, supportsDatabaseSwitching: true, isReadOnly: false
        ))
        #expect(!ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .sql, supportsDatabaseSwitching: false, isReadOnly: false
        ))
        #expect(!ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .sql, supportsDatabaseSwitching: true, isReadOnly: true
        ))
        #expect(!ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .javascript, supportsDatabaseSwitching: true, isReadOnly: false
        ))
    }

    // MARK: - Namespaces

    /// The name an engine qualifies its objects with, which is not always the selected schema.
    /// MySQL has no schemas and reports the database in the schema column, so its foreign keys and
    /// routines come back qualified by the database name.
    @Test
    func theNamespaceIsTheSchemaWhereSchemasExist() {
        #expect(ObjectCopyNamespace.name(
                for: endpoint("app", type: .postgresql, schema: "sales"),
                supportsSchemas: true,
                supportsDatabases: true
            ) == "sales")
    }

    @Test
    func theNamespaceIsTheDatabaseWhereSchemasDoNot() {
        #expect(ObjectCopyNamespace.name(
                for: endpoint("shop"), supportsSchemas: false, supportsDatabases: true
            ) == "shop")
    }

    /// SQLite has one unnamed container, so nothing is qualified and two files compare equal.
    @Test
    func anEngineWithNeitherHasNoNamespace() {
        #expect(ObjectCopyNamespace.name(
            for: endpoint("chinook.sqlite", type: .sqlite),
            supportsSchemas: false,
            supportsDatabases: false
        ) == nil)
    }

    // MARK: - Definitions

    /// Nothing parses the definition, so every object it names keeps the source's qualification.
    /// A duplicate keeps the schema name, which is why one is copyable; two MySQL databases are
    /// two namespaces, which is why one is not.
    @Test
    func aDefinitionOnlyCopiesWithinOneNamespace() {
        #expect(ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "public", targetNamespace: "public"
        ))
        #expect(ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "Public", targetNamespace: "public"
        ))
        #expect(ObjectCopyEligibility.canCopyDefinition(sourceNamespace: nil, targetNamespace: nil))
        #expect(!ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "shop", targetNamespace: "shop_copy"
        ))
        #expect(!ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "sales", targetNamespace: nil
        ))
    }

    /// ClickHouse, Oracle, Dameng and BigQuery answer with the view's SELECT rather than its
    /// CREATE. Running that is a read the runner would report as the view copied, after Replace
    /// had already dropped the target's.
    @Test
    func aBareBodyIsNotAnExecutableDefinition() {
        let postgres = SQLScriptText(databaseType: .postgresql)

        #expect(SourceDefinitionDefect.of(definition: "CREATE VIEW v AS SELECT 1", sentAs: postgres) == nil)
        #expect(SourceDefinitionDefect.of(definition: "\n  create or replace view v AS SELECT 1", sentAs: postgres) == nil)
        #expect(SourceDefinitionDefect.of(definition: "SELECT id, name FROM orders", sentAs: postgres) == .notACreateStatement)
        #expect(SourceDefinitionDefect.of(definition: "   ", sentAs: postgres) == .empty)
    }
}
