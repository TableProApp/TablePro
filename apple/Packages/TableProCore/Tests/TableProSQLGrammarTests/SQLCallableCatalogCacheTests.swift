import Foundation
import TableProSQLGrammar
import Testing

struct SQLCallableCatalogCacheTests {
    private struct Unreachable: Error {}

    // Answers the two catalog queries the way Oracle 23ai answered them for the probe schema.
    private final class CatalogServer: @unchecked Sendable {
        private let lock = NSLock()
        private var queries: [String] = []
        private var failing = false

        var catalogReads: Int { lock.withLock { queries.filter { $0 == SQLCallableCatalog.query }.count } }
        var columnReads: Int { lock.withLock { queries.filter { $0 != SQLCallableCatalog.query }.count } }

        func fail() { lock.withLock { failing = true } }

        func read(_ query: String) throws -> [[String?]] {
            let failing = lock.withLock {
                queries.append(query)
                return self.failing
            }
            if failing { throw Unreachable() }
            if query == SQLCallableCatalog.query {
                return [["F", "PURGE"], ["F", "WIPE"], ["R", "PK"]]
            }
            return [["0", "1", nil, "ID"], ["0", "1", nil, "PURGE"]]
        }
    }

    private static func reading(_ sql: String) -> SQLBareNameReading {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Oracle", declared: nil, session: nil)
        return SQLBareNameCalls.read(sql, databaseTypeId: "Oracle", readings: readings)
    }

    @Test("A column of the table runs, a function name does not, and the catalog is read once")
    func columnsAndFunctions() async throws {
        let server = CatalogServer()
        let cache = SQLCallableCatalogCache()
        let connection = UUID()

        let column = try await cache.callsFunction(
            Self.reading("SELECT purge FROM orders"), connectionId: connection, schema: nil, read: server.read
        )
        let call = try await cache.callsFunction(
            Self.reading("SELECT wipe FROM orders"), connectionId: connection, schema: nil, read: server.read
        )

        #expect(!column)
        #expect(call)
        #expect(server.catalogReads == 1)
        #expect(server.columnReads == 1)
    }

    @Test("A query naming no function asks for no columns")
    func noHitNoColumns() async throws {
        let server = CatalogServer()
        let calls = try await SQLCallableCatalogCache().callsFunction(
            Self.reading("SELECT id FROM orders"), connectionId: UUID(), schema: nil, read: server.read
        )

        #expect(!calls)
        #expect(server.columnReads == 0)
    }

    @Test("The catalog is kept per schema for its lifetime, and read again after it")
    func lifetimeAndSchema() async throws {
        let server = CatalogServer()
        let kept = SQLCallableCatalogCache(lifetime: .seconds(3_600))
        let expired = SQLCallableCatalogCache(lifetime: .zero)
        let connection = UUID()
        let reading = Self.reading("SELECT id FROM orders")

        _ = try await kept.callsFunction(reading, connectionId: connection, schema: nil, read: server.read)
        _ = try await kept.callsFunction(reading, connectionId: connection, schema: nil, read: server.read)
        #expect(server.catalogReads == 1)
        _ = try await kept.callsFunction(reading, connectionId: connection, schema: "HR", read: server.read)
        #expect(server.catalogReads == 2)

        _ = try await expired.callsFunction(reading, connectionId: connection, schema: nil, read: server.read)
        _ = try await expired.callsFunction(reading, connectionId: connection, schema: nil, read: server.read)
        #expect(server.catalogReads == 4)
    }

    @Test("A dotted call is refused without reading the catalog, and a failed read throws")
    func outrightAndFailure() async throws {
        let server = CatalogServer()
        let cache = SQLCallableCatalogCache()

        #expect(try await cache.callsFunction(
            Self.reading("SELECT pk.f FROM dual"), connectionId: UUID(), schema: nil, read: server.read
        ))
        #expect(server.catalogReads == 0)

        server.fail()
        await #expect(throws: Unreachable.self) {
            try await cache.callsFunction(
                Self.reading("SELECT id FROM orders"), connectionId: UUID(), schema: nil, read: server.read
            )
        }
    }
}
