//
//  ClickHouseRequestTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct ClickHouseRequestTests {
    private static let server2388 = ClickHouseServerProfile.testing(
        version: "23.8.8.20",
        writableSettings: ClickHouseServerProfile.writableSettings(
            columns: ClickHouseSettingsRows.columns20,
            rows: ClickHouseSettingsRows.server2388
        )
    )
    private static let server258 = ClickHouseServerProfile.testing(
        version: "25.8.33.6",
        writableSettings: Set(ClickHouseURLSetting.allCases)
    )
    private static let readonlyUser = ClickHouseServerProfile.testing(version: "25.8.33.6")

    private static func items(
        _ shape: ClickHouseResponseShape,
        _ profile: ClickHouseServerProfile,
        executionTimeLimit: Int? = nil,
        statementBytes: Int = 0
    ) -> [String: String] {
        let items = ClickHousePluginDriver.queryItems(
            database: "default",
            queryId: "q1",
            executionTimeLimit: executionTimeLimit,
            shape: shape,
            profile: profile,
            statementBytes: statementBytes
        )
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    @Test("Before the probes answer, a request carries only what every user may send")
    func bootstrapRequestIsMinimal() {
        let items = Self.items(.buffered(parameters: nil), .bootstrap)
        #expect(items == [
            "database": "default",
            "query_id": "q1",
            "default_format": "TabSeparatedWithNamesAndTypes",
            "wait_end_of_query": "1",
        ])
    }

    @Test("23.8.8.20 is never sent http_write_exception_in_output_format (#3444)")
    func server2388GetsNoWriteExceptionSetting() {
        let buffered = Self.items(.buffered(parameters: nil), Self.server2388)
        let streamed = Self.items(.streamed(rowCap: 100), Self.server2388)
        #expect(buffered["http_write_exception_in_output_format"] == nil)
        #expect(streamed["http_write_exception_in_output_format"] == nil)
        #expect(buffered["send_progress_in_http_headers"] == "1")
    }

    @Test("A server that knows the setting gets it on both shapes")
    func server258GetsWriteExceptionSetting() {
        #expect(Self.items(.buffered(parameters: nil), Self.server258)["http_write_exception_in_output_format"] == "0")
        #expect(Self.items(.streamed(rowCap: nil), Self.server258)["http_write_exception_in_output_format"] == "0")
    }

    /// A bounded read is collected whole anyway, and `wait_end_of_query` turns a failure into a
    /// status on every version. An unbounded one is an export and must not be held on the server.
    @Test("A bounded stream caps rows one past the cap and waits for the end; an unbounded one does neither")
    func shapesCarryTheirOwnItems() {
        let bounded = Self.items(.streamed(rowCap: 100), Self.server258)
        #expect(bounded["max_result_rows"] == "101")
        #expect(bounded["result_overflow_mode"] == "break")
        #expect(bounded["cancel_http_readonly_queries_on_client_close"] == "1")
        #expect(bounded["wait_end_of_query"] == "1")
        #expect(bounded["send_progress_in_http_headers"] == nil)

        let unbounded = Self.items(.streamed(rowCap: nil), Self.server258)
        #expect(unbounded["max_result_rows"] == nil)
        #expect(unbounded["cancel_http_readonly_queries_on_client_close"] == nil)
        #expect(unbounded["wait_end_of_query"] == nil)
    }

    @Test("A stream asks for an uncompressed body, a buffered read keeps compression")
    func streamsAskForIdentityEncoding() throws {
        let driver = ClickHouseStubServer().connectedDriver()
        let stream = try driver.buildRequest(
            query: "SELECT 1", database: "", queryId: nil, executionTimeLimit: nil, shape: .streamed(rowCap: nil)
        )
        let buffered = try driver.buildRequest(
            query: "SELECT 1", database: "", queryId: nil, executionTimeLimit: nil, shape: .buffered(parameters: nil)
        )
        #expect(stream.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(buffered.value(forHTTPHeaderField: "Accept-Encoding") == nil)
    }

    @Test("A read-only user gets no setting it cannot change, on either shape")
    func readonlyUserGetsNoSettings() {
        let buffered = Self.items(.buffered(parameters: nil), Self.readonlyUser)
        let streamed = Self.items(.streamed(rowCap: 100), Self.readonlyUser)
        for name in ClickHouseURLSetting.allCases.map(\.rawValue) {
            #expect(buffered[name] == nil, "\(name)")
            #expect(streamed[name] == nil, "\(name)")
        }
    }

    @Test("Without the server-side cap a bounded read is not held on the server")
    func uncappedBoundedReadIsNotHeld() {
        #expect(Self.items(.streamed(rowCap: 100), Self.readonlyUser)["wait_end_of_query"] == nil)
    }

    @Test("max_result_rows goes out only with result_overflow_mode, or an overflow would throw")
    func rowCapNeedsOverflowMode() {
        let rowsOnly = ClickHouseServerProfile.testing(writableSettings: [.maxResultRows])
        #expect(Self.items(.streamed(rowCap: 100), rowsOnly)["max_result_rows"] == nil)
    }

    @Test("A cap above the constraint's max leaves the bound to the reader")
    func rowCapAboveConstraint() {
        let limited = ClickHouseServerProfile(
            version: nil,
            settingLimits: [.maxResultRows: ClickHouseSettingLimits(max: 50), .resultOverflowMode: ClickHouseSettingLimits()],
            catalog: []
        )
        #expect(Self.items(.streamed(rowCap: 100), limited)["max_result_rows"] == nil)
        #expect(Self.items(.streamed(rowCap: 10), limited)["max_result_rows"] == "11")
    }

    @Test("Query parameters ride as param_ items on a buffered request")
    func parametersRideAsParamItems() {
        let items = Self.items(.buffered(parameters: ["b": "2", "a": nil]), Self.server258)
        #expect(items["param_a"] == "")
        #expect(items["param_b"] == "2")
    }

    @Test("A statement longer than max_query_size gets room for exactly itself")
    func longStatementGetsItsOwnQuerySize() {
        let profile = ClickHouseServerProfile.testing(writableSettings: [.maxQuerySize])
        #expect(Self.items(.buffered(parameters: nil), profile, statementBytes: 300_080)["max_query_size"] == "300080")
        #expect(Self.items(.streamed(rowCap: nil), profile, statementBytes: 300_080)["max_query_size"] == "300080")
        #expect(Self.items(.buffered(parameters: nil), profile, statementBytes: 262_144)["max_query_size"] == nil)
        #expect(Self.items(.buffered(parameters: nil), profile)["max_query_size"] == nil)
    }

    @Test("The user's own max_query_size decides when a statement needs more")
    func statementComparesWithTheUsersLimit() {
        let lowered = ClickHouseServerProfile(
            version: nil, writableSettings: [.maxQuerySize], catalog: [], maxQuerySize: 100_000
        )
        let raised = ClickHouseServerProfile(
            version: nil, writableSettings: [.maxQuerySize], catalog: [], maxQuerySize: 10_485_760
        )
        #expect(Self.items(.buffered(parameters: nil), lowered, statementBytes: 150_000)["max_query_size"] == "150000")
        #expect(Self.items(.buffered(parameters: nil), raised, statementBytes: 1_000_000)["max_query_size"] == nil)
    }

    @Test("max_query_size is not sent to a user who may not set it, or above a constraint's max")
    func querySizeFollowsTheProfile() {
        let constrained = ClickHouseServerProfile(
            version: nil,
            settingLimits: [.maxQuerySize: ClickHouseSettingLimits(max: 500_000)],
            catalog: []
        )
        let buffered = ClickHouseResponseShape.buffered(parameters: nil)
        #expect(Self.items(buffered, Self.readonlyUser, statementBytes: 300_000)["max_query_size"] == nil)
        #expect(Self.items(buffered, constrained, statementBytes: 600_000)["max_query_size"] == nil)
        #expect(Self.items(buffered, constrained, statementBytes: 400_000)["max_query_size"] == "400000")
    }

    // #3777: as `param_` items the server refused a value over 128 KiB and a URL over 1 MiB.
    @Test("A long bound value travels in the body, never the URL, and the statement says how long it is")
    func longBoundValueTravelsInTheBody() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()
        driver.serverProfile = ClickHouseServerProfile.testing(writableSettings: [.maxQuerySize])
        let short = String(repeating: "a", count: 200_000)
        let long = String(repeating: "b", count: 300_000)

        _ = try await driver.executeParameterized(query: "INSERT INTO t (s) VALUES (?)", parameters: [.text(short)])
        _ = try await driver.executeParameterized(
            query: "ALTER TABLE t UPDATE s = ? WHERE id = ?", parameters: [.text(long), .text("1")]
        )

        let requests = server.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(!request.queryItems.keys.contains { $0.hasPrefix("param_") })
        }
        #expect(requests.first?.body == "INSERT INTO t (s) VALUES (CAST('\(short)' AS String))")
        #expect(requests.first?.item("max_query_size") == nil)
        let update = "ALTER TABLE t UPDATE s = '\(long)' WHERE id = '1'"
        #expect(requests.last?.body == update)
        #expect(requests.last?.item("max_query_size") == String(update.utf8.count))
    }

    // A data sync writes its values into the statements it runs, so a long one needs the same room.
    @Test("A statement without bound values that is longer than max_query_size gets room too")
    func plainStatementGetsItsOwnQuerySize() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()
        driver.serverProfile = ClickHouseServerProfile.testing(writableSettings: [.maxQuerySize])
        let statement = "ALTER TABLE t UPDATE s = '\(String(repeating: "c", count: 300_000))' WHERE id = 1"

        _ = try await driver.execute(query: statement + ";")

        #expect(server.requests.first?.item("max_query_size") == String(statement.utf8.count))
    }

    // Measured on 25.8: `param_p=a+b` arrived as `a b`, since the server decodes a form-encoded `+` as a space.
    @Test("A plus sign in a URL value is percent-encoded")
    func plusSignIsEncoded() throws {
        let driver = ClickHouseStubServer().connectedDriver()
        let request = try driver.buildRequest(
            query: "SELECT {p1:String}", database: "a+b", queryId: nil, executionTimeLimit: nil,
            shape: .buffered(parameters: ["p1": "+1 555 & x=y"])
        )
        let query = try #require(request.url?.absoluteString)
        #expect(query.contains("database=a%2Bb"))
        #expect(query.contains("param_p1=%2B1%20555%20%26%20x%3Dy"))
    }

    @Test("An accepted execution time limit rides on both shapes")
    func executionTimeLimitRidesOnBothShapes() {
        #expect(Self.items(.buffered(parameters: nil), .bootstrap, executionTimeLimit: 30)["max_execution_time"] == "30")
        #expect(Self.items(.streamed(rowCap: 5), .bootstrap, executionTimeLimit: 30)["max_execution_time"] == "30")
    }

    @Test("Trailing semicolons and the space between them are trimmed")
    func trailingSemicolonsAreTrimmed() {
        #expect(ClickHousePluginDriver.withoutTrailingSemicolons("SELECT 1 ; ;\n") == "SELECT 1")
        #expect(ClickHousePluginDriver.withoutTrailingSemicolons("SELECT ';'") == "SELECT ';'")
    }
}
