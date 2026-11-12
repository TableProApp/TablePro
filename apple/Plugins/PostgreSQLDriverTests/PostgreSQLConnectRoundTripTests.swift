//
//  PostgreSQLConnectRoundTripTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PostgreSQLConnectRoundTripTests {
    private static let probes = [
        PostgreSQLSessionFacts.probeQuery,
        PostgreSQLCatalogPresence.probeQuery,
        PostGISTypes.probeQuery,
        PostgreSQLSchemaQueries.enumTypeOidQuery,
        PgvectorTypes.probeQuery
    ]

    private static func connectedDriver(to server: LibPQScriptedServer) async throws -> PostgreSQLPluginDriver {
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: server.port, username: "postgres", password: "", database: "postgres"
        ))
        try await driver.connect()
        return driver
    }

    private static func probeCount(in query: String) -> Int {
        probes.filter { query.contains($0) }.count
    }

    @Test("Connect sends the five catalog probes in one Query and no string setting the server reports on")
    func probesShareOneQuery() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let sent = server.queries
        let carriers = sent.filter { Self.probeCount(in: $0) > 0 }
        let batch = try #require(carriers.first)
        let settingSent = sent.contains { $0.contains(LibPQStringConformance.parameterName) }
        #expect(carriers.count == 1)
        #expect(Self.probeCount(in: batch) == Self.probes.count)
        #expect(batch.hasPrefix(PostgreSQLCatalogSearchPath.pinned))
        #expect(!settingSent)
    }

    @Test("A probe the server refuses costs no other: each probe after it goes again in its own Query")
    func failedProbeLeavesTheRestSent() async throws {
        let server = try LibPQScriptedServer(failingStatement: PostGISTypes.probeQuery)
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let sent = server.queries
        let found = sent.firstIndex { Self.probeCount(in: $0) == Self.probes.count }
        let batchIndex = try #require(found)
        let resent = sent[(batchIndex + 1)...].filter { Self.probeCount(in: $0) > 0 }
        let eachAlone = resent.allSatisfy { Self.probeCount(in: $0) == 1 }
        #expect(resent.count == 2)
        #expect(eachAlone)
        #expect(resent.first?.contains(PostgreSQLSchemaQueries.enumTypeOidQuery) == true)
        #expect(resent.last?.contains(PgvectorTypes.probeQuery) == true)
    }
}
