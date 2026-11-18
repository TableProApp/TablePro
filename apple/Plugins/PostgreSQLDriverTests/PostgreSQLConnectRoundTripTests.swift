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

    private static func connectedDriver(
        to server: LibPQScriptedServer,
        additionalFields: [String: String] = [:]
    ) async throws -> PostgreSQLPluginDriver {
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1",
            port: server.port,
            username: "postgres",
            password: "",
            database: "postgres",
            additionalFields: additionalFields
        ))
        try await driver.connect()
        return driver
    }

    private static func probeCount(in query: String) -> Int {
        probes.filter { query.contains($0) }.count
    }

    private static let scanSetting = "set_config('synchronize_seqscans', 'off', false)"

    @Test("Connect sends the schema read, the five catalog probes and the session settings in one Query")
    func probesShareOneQuery() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server, additionalFields: ["queryTimeoutSeconds": "60"])
        defer { driver.disconnect() }

        let sent = server.queries
        let carriers = sent.filter { Self.probeCount(in: $0) > 0 }
        let batch = try #require(carriers.first)
        let settingSent = sent.contains { $0.contains(LibPQStringConformance.parameterName) }
        let pin = try #require(batch.range(of: "SET LOCAL search_path = pg_catalog, pg_temp"))
        let schemaRead = try #require(batch.range(of: PostgreSQLSchemaQueries.currentSchema))
        let timeout = try #require(batch.range(of: "SET statement_timeout = 60000"))
        let scan = try #require(batch.range(of: Self.scanSetting))
        #expect(carriers.count == 1)
        #expect(Self.probeCount(in: batch) == Self.probes.count)
        #expect(schemaRead.lowerBound < pin.lowerBound)
        #expect(timeout.lowerBound < scan.lowerBound)
        #expect(!sent.contains(PostgreSQLSchemaQueries.currentSchema))
        #expect(!settingSent)
    }

    @Test("The scan setting names this session's backend, so a pooler's server session is left alone")
    func scanSettingIsGuardedByTheBackendProcess() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let batch = try #require(server.queries.first { Self.probeCount(in: $0) > 0 })
        #expect(batch.contains("pg_catalog.pg_backend_pid() OPERATOR(pg_catalog.=) \(LibPQScriptedServer.backendProcessID)"))
    }

    @Test("A scan setting named in the connection options stays the person's")
    func scanSettingInOptionsIsKept() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(
            to: server,
            additionalFields: ["connectionOptions": "-c synchronize_seqscans=on"]
        )
        defer { driver.disconnect() }

        #expect(!server.queries.contains { $0.contains(Self.scanSetting) })
    }

    @Test("The host's timeout, already applied by the connect, costs no round trip of its own")
    func appliedTimeoutIsNotSentAgain() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server, additionalFields: ["queryTimeoutSeconds": "60"])
        defer { driver.disconnect() }

        try await driver.applyQueryTimeout(60)
        #expect(!server.queries.contains("SET statement_timeout = 60000"))

        try await driver.applyQueryTimeout(60)
        #expect(server.queries.contains("SET statement_timeout = 60000"))
    }

    @Test("A connect whose batch failed leaves the host's timeout to go out")
    func failedBatchLeavesTheTimeoutToTheHost() async throws {
        let server = try LibPQScriptedServer(failingStatement: PostGISTypes.probeQuery)
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server, additionalFields: ["queryTimeoutSeconds": "60"])
        defer { driver.disconnect() }

        try await driver.applyQueryTimeout(60)
        #expect(server.queries.contains("SET statement_timeout = 60000"))
    }

    @Test("A timeout other than the one the connect applied is sent")
    func differentTimeoutIsSent() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server, additionalFields: ["queryTimeoutSeconds": "60"])
        defer { driver.disconnect() }

        try await driver.applyQueryTimeout(30)
        #expect(server.queries.contains("SET statement_timeout = 30000"))
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

    @Test("A setting the failed probe kept from running goes out alone")
    func failedProbeStillSendsTheScanSetting() async throws {
        let server = try LibPQScriptedServer(failingStatement: PostGISTypes.probeQuery)
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let alone = server.queries.filter { $0.hasPrefix("SELECT pg_catalog.set_config") }
        #expect(alone.count == 1)
    }

    @Test("PGlite never gets the scan setting")
    func pgliteStaysUntouched() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = PGlitePluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: server.port, username: "postgres", password: "", database: "postgres"
        ))
        try await driver.connect()
        defer { driver.disconnect() }

        #expect(!server.queries.contains { $0.contains(Self.scanSetting) })
    }
}
