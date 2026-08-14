import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@testable import TablePro  // for TestFixtures if needed, but assume it's in test target

@Suite("WorkspaceContext")
struct WorkspaceContextTests {
    @Test("PostgreSQL contexts include database and schema")
    func schemaAwareContext() {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let key = WorkspaceContextKey.resolve(
            connection: connection,
            databaseName: "app",
            schemaName: "audit",
            activeDatabase: "ignored",
            activeSchema: "public",
            supportsSchemaSwitching: true
        )
        #expect(key.connectionId == connection.id)
        #expect(key.databaseName == "app")
        #expect(key.schemaName == "audit")
    }

    @Test("Engines without schema switching normalize schema to nil")
    func schemaBlindContext() {
        let connection = TestFixtures.makeConnection(database: "app", type: .mysql)
        let key = WorkspaceContextKey.resolve(
            connection: connection,
            databaseName: nil,
            schemaName: "ignored",
            activeDatabase: nil,
            activeSchema: "ignored",
            supportsSchemaSwitching: false
        )
        #expect(key.databaseName == "app")
        #expect(key.schemaName == nil)
    }

    @Test("Identifiers cannot collide when names contain separators")
    func collisionSafeIdentifier() {
        let connectionId = UUID()
        let first = WorkspaceContextKey(connectionId: connectionId, databaseName: "a.b", schemaName: "c")
        let second = WorkspaceContextKey(connectionId: connectionId, databaseName: "a", schemaName: "b.c")
        #expect(first.tabbingIdentifier != second.tabbingIdentifier)
    }

    @Test("Explicit names win over live and configured fallbacks")
    func precedence() {
        let connection = TestFixtures.makeConnection(database: "configured")
        let key = WorkspaceContextKey.resolve(
            connection: connection,
            databaseName: "payload",
            schemaName: nil,
            activeDatabase: "live",
            activeSchema: nil,
            supportsSchemaSwitching: false
        )
        #expect(key.databaseName == "payload")
    }
}
