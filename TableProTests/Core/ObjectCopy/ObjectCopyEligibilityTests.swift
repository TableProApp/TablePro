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

    // MARK: - Schemas

    /// `fetchTables(schema: nil)` resolves to the connection's current schema, so a whole-database
    /// copy taken without one carried one schema and reported success over the rest.
    func testASchemaAwareEngineMustNameASchema() {
        XCTAssertNotNil(ObjectCopyEligibility.unscopedSchemaRefusal(
            endpoint: endpoint("app", type: .postgresql), supportsSchemas: true
        ))
        XCTAssertNil(ObjectCopyEligibility.unscopedSchemaRefusal(
            endpoint: endpoint("app", type: .postgresql, schema: "public"), supportsSchemas: true
        ))
    }

    func testAnEngineWithoutSchemasNeedsNone() {
        XCTAssertNil(ObjectCopyEligibility.unscopedSchemaRefusal(
            endpoint: endpoint("app"), supportsSchemas: false
        ))
    }

    // MARK: - Definitions

    /// Nothing parses the definition, so every table it names keeps the source's qualification.
    /// Into another schema it would point back at the source, and a replacement's DROP would land
    /// on the source's own object.
    func testADefinitionOnlyCopiesIntoASchemaOfTheSameName() {
        XCTAssertTrue(ObjectCopyEligibility.canCopyDefinition(sourceSchema: "public", targetSchema: "public"))
        XCTAssertTrue(ObjectCopyEligibility.canCopyDefinition(sourceSchema: "Public", targetSchema: "public"))
        XCTAssertTrue(ObjectCopyEligibility.canCopyDefinition(sourceSchema: nil, targetSchema: nil))
        XCTAssertFalse(ObjectCopyEligibility.canCopyDefinition(sourceSchema: "sales", targetSchema: "archive"))
        XCTAssertFalse(ObjectCopyEligibility.canCopyDefinition(sourceSchema: "sales", targetSchema: nil))
    }
}
