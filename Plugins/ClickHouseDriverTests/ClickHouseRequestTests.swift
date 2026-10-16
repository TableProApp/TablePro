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
        executionTimeLimit: Int? = nil
    ) -> [String: String] {
        let items = ClickHousePluginDriver.queryItems(
            database: "default",
            queryId: "q1",
            executionTimeLimit: executionTimeLimit,
            shape: shape,
            profile: profile
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
