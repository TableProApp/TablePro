//
//  MySQLColumnFlightTests.swift
//  TableProTests
//

import Foundation
import TableProMySQLCore
import TableProPluginKit
import Testing

struct MySQLColumnFlightTests {
    private static let unknownColumn = MariaDBPluginError(code: 1_054, message: "Unknown column 'LEVEL'", sqlState: "42S22")
    private static let denied = MariaDBPluginError(code: 1_142, message: "SELECT command denied", sqlState: "42000")
    private static let lost = MariaDBPluginError(code: 2_013, message: "Lost connection", sqlState: "HY000")

    private func rows(_ values: String...) -> Result<PluginQueryResult, MariaDBPluginError> {
        .success(PluginQueryResult(
            columns: ["value"],
            columnTypeNames: ["VARCHAR"],
            rows: values.map { [PluginCellValue.text($0)] },
            rowsAffected: 0,
            executionTime: 0
        ))
    }

    private func outcome(
        _ flight: MySQLColumnFlight,
        _ answers: [Result<PluginQueryResult, MariaDBPluginError>]
    ) throws -> MySQLColumnFlight.Outcome {
        try flight.outcome(of: answers, settlesBlindness: { $0 == 1_142 })
    }

    @Test("A session holding nothing may use a flight")
    func cleanSessionMayFly() {
        #expect(MySQLColumnFlight.mayRun(on: MySQLSessionFootprint(), isRefused: false))
    }

    @Test("A session that refused a flight stays on the one-by-one reads")
    func refusedSessionMayNotFly() {
        #expect(!MySQLColumnFlight.mayRun(on: MySQLSessionFootprint(), isRefused: true))
    }

    @Test("A session holding state stays on the one-by-one reads", arguments: [
        "BEGIN",
        "START TRANSACTION",
        "SET @marker = 1",
        "SET sql_mode = ''",
        "CREATE TEMPORARY TABLE t (id INT)",
        "LOCK TABLES t READ",
    ])
    func heldSessionMayNotFly(sql: String) {
        var footprint = MySQLSessionFootprint()
        footprint.observe(sql, lexicalFeatures: MySQLLexicalFeatures.mySQL)
        #expect(!MySQLColumnFlight.mayRun(on: footprint, isRefused: false))
    }

    @Test("A flight that outlasted the socket timeout is reported and never read again")
    func outlastedFlightIsReported() {
        var timedOut = Self.lost
        timedOut.outlastedSocketTimeout = true
        let response = MySQLColumnFlight.FailureResponse(to: timedOut)
        #expect(response.reportsFailure)
        #expect(response.stopsFlights)
    }

    @Test("A flight that lost its connection falls back and stops using flights")
    func lostFlightFallsBack() {
        let response = MySQLColumnFlight.FailureResponse(to: Self.lost)
        #expect(!response.reportsFailure)
        #expect(response.stopsFlights)
    }

    @Test("A flight the driver could not start falls back and keeps using flights")
    func unstartedFlightFallsBack() {
        let response = MySQLColumnFlight.FailureResponse(to: .notSentAfterSessionEnded)
        #expect(!response.reportsFailure)
        #expect(!response.stopsFlights)
    }

    @Test("MySQL reads the columns and the catalog")
    func mysqlReads() {
        let flight = MySQLColumnFlight(readsChecks: false, levelIsPresent: nil)
        #expect(flight.reads == [.columns, .catalogDetails])
    }

    @Test("MariaDB asks about LEVEL in the same flight until the answer is known")
    func mariadbReadsLevelOnce() {
        #expect(
            MySQLColumnFlight(readsChecks: true, levelIsPresent: nil).reads
                == [.columns, .catalogDetails, .levelPresence, .checkClauses]
        )
        #expect(
            MySQLColumnFlight(readsChecks: true, levelIsPresent: true).reads
                == [.columns, .catalogDetails, .checkClauses]
        )
    }

    @Test("A server known to have no LEVEL column is not asked for clauses")
    func noLevelNoClauses() {
        #expect(MySQLColumnFlight(readsChecks: true, levelIsPresent: false).reads == [.columns, .catalogDetails])
    }

    @Test("Answers are read in the order the statements went out")
    func answersFollowTheReads() throws {
        let flight = MySQLColumnFlight(readsChecks: true, levelIsPresent: nil)
        let result = try outcome(flight, [rows("id"), rows("detail"), rows("1"), rows("`id` > 0")])
        #expect(result.showRows == [[.text("id")]])
        #expect(result.catalogRows == [[.text("detail")]])
        #expect(result.levelIsPresent == true)
        #expect(result.checkClauses == ["`id` > 0"])
        #expect(result.refusals.isEmpty)
    }

    @Test("A refused column list fails the read, even with a code the catalog rule settles")
    func refusedColumnsAreFatal() {
        let flight = MySQLColumnFlight(readsChecks: false, levelIsPresent: nil)
        #expect(throws: MariaDBPluginError.self) {
            try outcome(flight, [.failure(Self.denied), rows("detail")])
        }
    }

    @Test("A refused catalog read degrades to no details")
    func refusedCatalogDegrades() throws {
        let flight = MySQLColumnFlight(readsChecks: false, levelIsPresent: nil)
        let result = try outcome(flight, [rows("id"), .failure(Self.denied)])
        #expect(result.showRows == [[.text("id")]])
        #expect(result.catalogRows.isEmpty)
        #expect(result.refusals == [MySQLColumnFlight.Refusal(code: 1_142, message: "SELECT command denied")])
    }

    @Test("A catalog failure the rule does not settle fails the read")
    func unsettledCatalogFailureIsFatal() {
        let flight = MySQLColumnFlight(readsChecks: false, levelIsPresent: nil)
        #expect(throws: MariaDBPluginError.self) {
            try outcome(flight, [rows("id"), .failure(Self.lost)])
        }
    }

    @Test("Clauses a server without LEVEL refused are not a failure")
    func clausesRefusedWithoutLevelAreIgnored() throws {
        let flight = MySQLColumnFlight(readsChecks: true, levelIsPresent: nil)
        let result = try outcome(flight, [rows("id"), rows("detail"), rows("0"), .failure(Self.unknownColumn)])
        #expect(result.levelIsPresent == false)
        #expect(result.checkClauses.isEmpty)
        #expect(result.refusals.isEmpty)
    }

    @Test("A refused LEVEL question is asked again next time and reads no clauses")
    func refusedLevelIsNotRemembered() throws {
        let flight = MySQLColumnFlight(readsChecks: true, levelIsPresent: nil)
        let result = try outcome(flight, [rows("id"), rows("detail"), .failure(Self.denied), .failure(Self.unknownColumn)])
        #expect(result.levelIsPresent == nil)
        #expect(result.checkClauses.isEmpty)
    }

    @Test("Clauses that fail where LEVEL exists fail the read")
    func clauseFailureWithLevelIsFatal() {
        let flight = MySQLColumnFlight(readsChecks: true, levelIsPresent: true)
        #expect(throws: MariaDBPluginError.self) {
            try outcome(flight, [rows("id"), rows("detail"), .failure(Self.unknownColumn)])
        }
    }
}
