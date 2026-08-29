//
//  ObjectCopyEligibilityTests.swift
//  TableProTests
//
//  Every refusal a copy can make before it opens a driver.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class ObjectCopyEligibilityTests: XCTestCase {
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

    func testAReadOnlyTargetIsRefused() {
        XCTAssertNotNil(ObjectCopyEligibility.targetRefusal(endpoint("app", safeMode: .readOnly)))
        XCTAssertNil(ObjectCopyEligibility.targetRefusal(endpoint("app")))
    }

    /// Both halves of a copy are refused across engines, not only structure. The row writer emits
    /// `INSERT … VALUES`, which a MongoDB target cannot parse, and a SQL Server `dbo` source hands
    /// a MySQL target a schema that engine does not have.
    func testACopyStaysInsideOneEngine() {
        XCTAssertNotNil(ObjectCopyEligibility.engineRefusal(from: .mysql, to: .postgresql))
        XCTAssertNotNil(ObjectCopyEligibility.engineRefusal(from: .mssql, to: .mysql))
        XCTAssertNil(ObjectCopyEligibility.engineRefusal(from: .mysql, to: .mysql))
        XCTAssertNil(ObjectCopyEligibility.engineRefusal(from: .mysql, to: .mariadb))
    }

    /// Copying a database onto itself either drops the rows it is about to read or doubles them.
    func testTheSameScopeIsRefusedAsATarget() {
        let connectionId = UUID()
        let source = endpoint("app", connectionId: connectionId)
        let same = endpoint("app", connectionId: connectionId)
        let other = endpoint("app_copy", connectionId: connectionId)

        XCTAssertNotNil(ObjectCopyEligibility.sameObjectRefusal(source: source, target: same))
        XCTAssertNil(ObjectCopyEligibility.sameObjectRefusal(source: source, target: other))
    }

    /// Two databases on one server are a valid pair, which is the case the endpoint type exists for.
    func testTwoDatabasesOnOneConnectionAreAValidPair() {
        let connectionId = UUID()
        XCTAssertNil(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("prod", connectionId: connectionId),
            target: endpoint("staging", connectionId: connectionId)
        ))
    }

    /// Right-clicking a PostgreSQL database gives a source with no schema, and choosing that same
    /// database's `public` as the target used to pass every refusal because the two endpoint ids
    /// differ. The planner then resolved both sides to `public` and dropped each table before
    /// streaming from the table it had just emptied.
    func testAScopedTargetInsideAnUnscopedSourceIsRefused() {
        let connectionId = UUID()
        let wholeDatabase = endpoint("app", type: .postgresql, connectionId: connectionId)
        let oneSchema = endpoint("app", type: .postgresql, schema: "public", connectionId: connectionId)

        XCTAssertNotNil(ObjectCopyEligibility.sameObjectRefusal(source: wholeDatabase, target: oneSchema))
        XCTAssertNotNil(ObjectCopyEligibility.sameObjectRefusal(source: oneSchema, target: wholeDatabase))
    }

    func testTheSameSchemaIsRefusedWhateverItsCase() {
        let connectionId = UUID()
        XCTAssertNotNil(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "Sales", connectionId: connectionId),
            target: endpoint("app", type: .postgresql, schema: "sales", connectionId: connectionId)
        ))
    }

    /// The case the refusal must not swallow: two schemas of one database are a valid pair, and
    /// copying between them is the whole point of a schema-scoped endpoint.
    func testTwoSchemasOfOneDatabaseAreAValidPair() {
        let connectionId = UUID()
        XCTAssertNil(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "sales", connectionId: connectionId),
            target: endpoint("app", type: .postgresql, schema: "archive", connectionId: connectionId)
        ))
        XCTAssertNil(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "public", connectionId: connectionId),
            target: endpoint("app_copy", type: .postgresql, schema: "public", connectionId: connectionId)
        ))
    }

    /// An empty schema is how a scope with none is spelled, so it has to read as absent rather than
    /// as a schema literally named "".
    func testAnEmptySchemaCountsAsNoSchema() {
        let connectionId = UUID()
        XCTAssertNotNil(ObjectCopyEligibility.sameObjectRefusal(
            source: endpoint("app", type: .postgresql, schema: "", connectionId: connectionId),
            target: endpoint("app", type: .postgresql, schema: "public", connectionId: connectionId)
        ))
    }

    func testOnlySQLEnginesCanCopy() {
        XCTAssertTrue(ObjectCopyEligibility.supportsCopying(editorLanguage: .sql))
        XCTAssertFalse(ObjectCopyEligibility.supportsCopying(editorLanguage: .javascript))
        XCTAssertFalse(ObjectCopyEligibility.supportsCopying(editorLanguage: .custom("mql")))
    }

    func testDuplicateIsOnlyOfferedWhereDatabasesExistAndCanBeWritten() {
        XCTAssertTrue(ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .sql, supportsDatabaseSwitching: true, isReadOnly: false
        ))
        XCTAssertFalse(ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .sql, supportsDatabaseSwitching: false, isReadOnly: false
        ))
        XCTAssertFalse(ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .sql, supportsDatabaseSwitching: true, isReadOnly: true
        ))
        XCTAssertFalse(ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: .javascript, supportsDatabaseSwitching: true, isReadOnly: false
        ))
    }

    // MARK: - Namespaces

    /// The name an engine qualifies its objects with, which is not always the selected schema.
    /// MySQL has no schemas and reports the database in the schema column, so its foreign keys and
    /// routines come back qualified by the database name.
    func testTheNamespaceIsTheSchemaWhereSchemasExist() {
        XCTAssertEqual(
            ObjectCopyNamespace.name(
                for: endpoint("app", type: .postgresql, schema: "sales"),
                supportsSchemas: true,
                supportsDatabases: true
            ),
            "sales"
        )
    }

    func testTheNamespaceIsTheDatabaseWhereSchemasDoNot() {
        XCTAssertEqual(
            ObjectCopyNamespace.name(
                for: endpoint("shop"), supportsSchemas: false, supportsDatabases: true
            ),
            "shop"
        )
    }

    /// SQLite has one unnamed container, so nothing is qualified and two files compare equal.
    func testAnEngineWithNeitherHasNoNamespace() {
        XCTAssertNil(ObjectCopyNamespace.name(
            for: endpoint("chinook.sqlite", type: .sqlite),
            supportsSchemas: false,
            supportsDatabases: false
        ))
    }

    // MARK: - Definitions

    /// Nothing parses the definition, so every object it names keeps the source's qualification.
    /// A duplicate keeps the schema name, which is why one is copyable; two MySQL databases are
    /// two namespaces, which is why one is not.
    func testADefinitionOnlyCopiesWithinOneNamespace() {
        XCTAssertTrue(ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "public", targetNamespace: "public"
        ))
        XCTAssertTrue(ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "Public", targetNamespace: "public"
        ))
        XCTAssertTrue(ObjectCopyEligibility.canCopyDefinition(sourceNamespace: nil, targetNamespace: nil))
        XCTAssertFalse(ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "shop", targetNamespace: "shop_copy"
        ))
        XCTAssertFalse(ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: "sales", targetNamespace: nil
        ))
    }

    /// ClickHouse, Oracle, Dameng and BigQuery answer with the view's SELECT rather than its
    /// CREATE. Running that is a read the runner would report as the view copied, after Replace
    /// had already dropped the target's.
    func testABareBodyIsNotAnExecutableDefinition() {
        XCTAssertTrue(ObjectCopyEligibility.isExecutableDefinition("CREATE VIEW v AS SELECT 1"))
        XCTAssertTrue(ObjectCopyEligibility.isExecutableDefinition("\n  create or replace view v AS SELECT 1"))
        XCTAssertFalse(ObjectCopyEligibility.isExecutableDefinition("SELECT id, name FROM orders"))
        XCTAssertFalse(ObjectCopyEligibility.isExecutableDefinition("   "))
    }
}
