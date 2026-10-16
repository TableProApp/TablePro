//
//  ClickHouseConnectProfileTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Drives `connect()` against a stub that answers the version and the two probes the way the
/// measured servers did, then checks what the requests after it carry.
struct ClickHouseConnectProfileTests {
    private static let optionalSettingNames = Set(ClickHouseURLSetting.allCases.map(\.rawValue))

    private static func tsv(_ columns: [String], _ rows: [[String]]) -> ClickHouseStubReply {
        let lines = [columns, columns.map { _ in "String" }] + rows
        return ClickHouseStubReply(statusCode: 200, body: lines.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n")
    }

    private static func answer(
        _ request: ClickHouseStubRequest,
        version: String,
        settings: [ClickHouseURLSetting],
        readonly: String = "0",
        catalog: Set<ClickHouseCatalogFeature> = Set(ClickHouseCatalogFeature.allCases)
    ) -> ClickHouseStubReply {
        if request.body == "SELECT version()" {
            return tsv(["version()"], [[version]])
        }
        if request.body.hasPrefix("SELECT * FROM system.settings") {
            return tsv(
                ClickHouseSettingsRows.columns20,
                settings.map { [$0.rawValue, "0", "0", "", "\\N", "\\N", readonly] }
            )
        }
        if request.body.hasPrefix("SELECT hasColumnInTable(") {
            let features = ClickHouseCatalogFeature.allCases
            return tsv(features.map(\.rawValue), [features.map { catalog.contains($0) ? "1" : "0" }])
        }
        return .oneRow
    }

    private static func carriesOptionalSetting(_ request: ClickHouseStubRequest) -> Bool {
        !optionalSettingNames.isDisjoint(with: request.queryItems.keys)
    }

    @Test("Connected to 23.8.8.20, a query carries no write-exception setting (#3444)")
    func server2388() async throws {
        let server = ClickHouseStubServer { request in
            if request.item("http_write_exception_in_output_format") != nil {
                return ClickHouseStubReply(statusCode: 404, body: "Code: 115. DB::Exception: Setting http_write_exception_in_output_format is neither a builtin setting nor started with the prefix 'SQL_' registered for user-defined settings. (UNKNOWN_SETTING)")
            }
            return Self.answer(
                request,
                version: "23.8.8.20",
                settings: ClickHouseURLSetting.allCases.filter { $0 != .httpWriteExceptionInOutputFormat }
            )
        }
        let driver = server.unconnectedDriver()
        defer { driver.disconnect() }

        try await driver.connect()
        let result = try await driver.execute(query: "SELECT 42")

        #expect(result.rows.first?.first?.asText == "1")
        let query = try #require(server.requests.first { $0.body == "SELECT 42" })
        #expect(query.item("http_write_exception_in_output_format") == nil)
        #expect(query.item("send_progress_in_http_headers") == "1")
        #expect(driver.serverVersion == "23.8.8.20")
    }

    @Test("Connected to 25.8, the write-exception setting goes out")
    func server258() async throws {
        let server = ClickHouseStubServer { Self.answer($0, version: "25.8.33.6", settings: ClickHouseURLSetting.allCases) }
        let driver = server.unconnectedDriver()
        defer { driver.disconnect() }

        try await driver.connect()
        _ = try await driver.execute(query: "SELECT 42")

        let query = try #require(server.requests.first { $0.body == "SELECT 42" })
        #expect(query.item("http_write_exception_in_output_format") == "0")
    }

    @Test("Connect and its probes send no setting a server could refuse")
    func connectRequestsAreMinimal() async throws {
        let server = ClickHouseStubServer { Self.answer($0, version: "25.8.33.6", settings: ClickHouseURLSetting.allCases) }
        let driver = server.unconnectedDriver()
        defer { driver.disconnect() }

        try await driver.connect()

        #expect(server.requests.count == 3)
        #expect(!server.requests.contains(where: Self.carriesOptionalSetting))
    }

    @Test("A read-only user connects, queries and reads a capped result")
    func readonlyUser() async throws {
        let server = ClickHouseStubServer { request in
            if Self.carriesOptionalSetting(request) {
                return ClickHouseStubReply(statusCode: 500, body: "Code: 164. DB::Exception: Cannot modify setting in readonly mode. (READONLY)")
            }
            return Self.answer(request, version: "25.8.33.6", settings: ClickHouseURLSetting.allCases, readonly: "1")
        }
        let driver = server.unconnectedDriver()
        defer { driver.disconnect() }

        try await driver.connect()
        _ = try await driver.execute(query: "SELECT 42")
        let bounded = try await driver.executeBoundedQuery(query: "SELECT 43", rowCap: 10)

        #expect(bounded?.rows.count == 1)
        #expect(!server.requests.contains(where: Self.carriesOptionalSetting))
    }

    @Test("A settings probe that fails sends nothing optional afterwards")
    func failedSettingsProbe() async throws {
        let server = ClickHouseStubServer { request in
            if request.body.hasPrefix("SELECT * FROM system.settings") {
                return ClickHouseStubReply(statusCode: 500, body: "Code: 497. DB::Exception: Not enough privileges. (ACCESS_DENIED)")
            }
            return Self.answer(request, version: "25.8.33.6", settings: ClickHouseURLSetting.allCases)
        }
        let driver = server.unconnectedDriver()
        defer { driver.disconnect() }

        try await driver.connect()
        _ = try await driver.execute(query: "SELECT 42")

        let query = try #require(server.requests.first { $0.body == "SELECT 42" })
        #expect(!Self.carriesOptionalSetting(query))
    }

    /// On 25.8's shipped config a user with no system grants is not shown the skipping-index
    /// table, while comments, view text and functions still read.
    @Test("A user without system grants keeps comments and functions and skips the skipping indices")
    func userWithoutSystemGrants() async throws {
        let server = ClickHouseStubServer { request in
            Self.answer(
                request,
                version: "25.8.33.6",
                settings: ClickHouseURLSetting.allCases,
                catalog: Set(ClickHouseCatalogFeature.allCases).subtracting([.dataSkippingIndices])
            )
        }
        let driver = server.unconnectedDriver()
        defer { driver.disconnect() }

        try await driver.connect()

        #expect(driver.serverProfile.hasTableComments)
        #expect(driver.serverProfile.hasFunctionOrigin)
        #expect(!driver.serverProfile.hasDataSkippingIndices)
    }

    @Test("A server that refuses the version query fails the connect with its own answer")
    func refusedVersionQueryFailsConnect() async throws {
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 516, body: "Code: 516. DB::Exception: default: Authentication failed. (AUTHENTICATION_FAILED)")
        }
        let driver = server.unconnectedDriver()

        await #expect(throws: ClickHouseError.self) { try await driver.connect() }
        #expect(server.requests.count == 1)
    }
}
