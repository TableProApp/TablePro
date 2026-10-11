import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Shortcuts table and database pickers")
@MainActor
struct EntityQuerySuggestionsTests {
    private let redis = DatabaseConnection(name: "Cache", type: .redis, host: "127.0.0.1", port: 6_379)
    private let missingFile = DatabaseConnection(
        name: "Gone",
        type: .sqlite,
        database: "/private/var/tablepro-tests/\(UUID().uuidString)/Gone.sqlite"
    )

    @Test("the table picker names a deleted connection instead of listing nothing")
    func tablesOfDeletedConnectionThrow() async {
        let scope = TableListingScope(connectionId: UUID(), namespace: nil)

        await #expect(throws: IntentDataError.connectionNotFound) {
            try await TableEntityQuery.tables(in: scope, savedConnection: { _ in nil })
        }
    }

    @Test("the table picker says the connection type cannot take rows")
    func tablesOfUnsupportedTypeThrow() async {
        let connection = redis
        let scope = TableListingScope(connectionId: connection.id, namespace: nil)

        await #expect(throws: IntentDataError.unsupportedDatabaseType("Redis")) {
            try await TableEntityQuery.tables(in: scope, savedConnection: { _ in connection })
        }
    }

    @Test("the table picker reports a connection that fails to open")
    func tablesOfFailedConnectionThrow() async {
        let connection = missingFile
        let scope = TableListingScope(connectionId: connection.id, namespace: nil)

        let error = await #expect(throws: IntentDataError.self) {
            try await TableEntityQuery.tables(in: scope, savedConnection: { _ in connection })
        }
        guard case .connectionFailed = error else {
            Issue.record("expected connectionFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("the table picker stays empty until a connection is picked")
    func tablesWithoutConnectionListNothing() async throws {
        let tables = try await TableEntityQuery.tables(in: nil, savedConnection: { _ in
            Issue.record("looked up a connection before one was picked")
            return nil
        })

        #expect(tables.isEmpty)
    }

    @Test("the database picker names a deleted connection instead of listing nothing")
    func namespacesOfDeletedConnectionThrow() async {
        await #expect(throws: IntentDataError.connectionNotFound) {
            try await DatabaseEntityQuery.namespaces(of: UUID(), savedConnection: { _ in nil })
        }
    }

    @Test("the database picker says the connection type cannot take rows")
    func namespacesOfUnsupportedTypeThrow() async {
        let connection = redis

        await #expect(throws: IntentDataError.unsupportedDatabaseType("Redis")) {
            try await DatabaseEntityQuery.namespaces(of: connection.id, savedConnection: { _ in connection })
        }
    }

    @Test("the database picker stays empty until a connection is picked")
    func namespacesWithoutConnectionListNothing() async throws {
        let namespaces = try await DatabaseEntityQuery.namespaces(of: nil, savedConnection: { _ in
            Issue.record("looked up a connection before one was picked")
            return nil
        })

        #expect(namespaces.isEmpty)
    }
}
