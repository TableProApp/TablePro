//
//  OracleDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleDashboardProviderTests {
    private final class Server {
        private(set) var statements: [String] = []
        private let answer: (String) throws -> QueryResult

        init(_ answer: @escaping (String) throws -> QueryResult) {
            self.answer = answer
        }

        func execute(_ sql: String) throws -> QueryResult {
            statements.append(sql)
            return try answer(sql)
        }
    }

    private struct Refusal: Error {}

    private static func result(_ columns: [String], _ rows: [[String]]) -> QueryResult {
        QueryResult(
            columns: columns,
            columnTypes: [],
            rows: rows.map { $0.map { PluginCellValue.text($0) } },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    @Test("The release number comes after Release, whatever the banner calls the product", arguments: [
        ("Oracle Database 11g Express Edition Release 11.2.0.2.0 - 64bit Production", 11),
        ("Oracle Database 12c Enterprise Edition Release 12.2.0.1.0 - 64bit Production", 12),
        ("Oracle Database 18c Express Edition Release 18.0.0.0.0 - Production", 18),
        ("Oracle AI Database 26ai Free Release 23.26.3.0.0 - Develop, Learn, and Run for Fr", 23),
    ] as [(String, Int)])
    func readsTheRelease(banner: String, release: Int) {
        #expect(OracleDashboardProvider.release(from: banner) == release)
    }

    @Test("Cancel Query is offered from 18c, and when the banner could not be read")
    func cancelNeeds18c() {
        let old = OracleDashboardProvider(serverVersion: "Oracle Database 12c Enterprise Edition Release 12.2.0.1.0")
        let current = OracleDashboardProvider(serverVersion: "Oracle Database 19c Enterprise Edition Release 19.0.0.0.0")
        let unread = OracleDashboardProvider(serverVersion: nil)
        #expect(old.cancelQuerySQL(processId: "12,345") == nil)
        #expect(current.cancelQuerySQL(processId: "12,345") == "ALTER SYSTEM CANCEL SQL '12,345'")
        #expect(unread.cancelQuerySQL(processId: "12,345") != nil)
        #expect(old.killSessionSQL(processId: "12,345") == "ALTER SYSTEM KILL SESSION '12,345' IMMEDIATE")
    }

    @Test("A session is named by SID and serial number, and nothing else reaches the statement", arguments: [
        ("12,345", true),
        ("12", false),
        ("12,", false),
        (",345", false),
        ("1,2,3", false),
        ("12,345' IMMEDIATE --", false),
        ("12,345,@1", false),
    ] as [(String, Bool)])
    func processIdIsSidAndSerial(processId: String, accepted: Bool) {
        let provider = OracleDashboardProvider(serverVersion: nil)
        #expect(provider.acceptsProcessId(processId) == accepted)
        #expect((provider.killSessionSQL(processId: processId) != nil) == accepted)
    }

    @Test("Sessions read the upper-case columns Oracle returns")
    func sessionsMapColumns() async throws {
        let server = Server { _ in
            Self.result(
                ["SESSION_ID", "USERNAME", "SCHEMANAME", "STATUS", "LAST_CALL_ET", "SQL_TEXT"],
                [["55,59756", "APP", "APP", "ACTIVE", "75", "begin dbms_session.sleep(100); end;"]]
            )
        }
        let sessions = try await OracleDashboardProvider(serverVersion: nil).fetchSessions { try server.execute($0) }
        let session = try #require(sessions.first)
        #expect(session.id == "55,59756")
        #expect(session.user == "APP")
        #expect(session.database == "APP")
        #expect(session.state == "ACTIVE")
        #expect(session.durationSeconds == 75)
        #expect(session.query == "begin dbms_session.sleep(100); end;")
        #expect(server.statements.first?.contains("s.SID <> SYS_CONTEXT('USERENV', 'SID')") == true)
    }

    @Test("A pluggable database, whose instance metric view is empty, reads its own")
    func metricsFallBackToTheContainerView() async throws {
        let server = Server { sql in
            if sql.contains("V_$SYSMETRIC") { return Self.result(["METRIC_NAME", "VALUE"], []) }
            if sql.contains("V_$CON_SYSMETRIC") {
                return Self.result(["METRIC_NAME", "VALUE"], [
                    ["CPU Usage Per Sec", "6.8"],
                    ["Logical Reads Per Sec", "19.8"],
                ])
            }
            if sql.contains("COUNT(*)") { return Self.result(["COUNT(*)"], [["2"]]) }
            return Self.result(["UPTIME"], [["1298"]])
        }
        let metrics = try await OracleDashboardProvider(serverVersion: nil).fetchMetrics { try server.execute($0) }
        #expect(metrics.map { $0.id } == ["sessions", "cpu", "logical_reads", "uptime"])
        #expect(metrics.first { $0.id == "cpu" }?.value == "6.8")
        #expect(metrics.first { $0.id == "logical_reads" }?.value == "19.8")
        #expect(metrics.first { $0.id == "sessions" }?.value == "2")
    }

    @Test("The root container and a non-CDB stop at the instance view")
    func metricsStopAtTheInstanceView() async throws {
        let server = Server { sql in
            if sql.contains("V_$SYSMETRIC") {
                return Self.result(["METRIC_NAME", "VALUE"], [["CPU Usage Per Sec", "2.7"]])
            }
            return Self.result(["X"], [["1"]])
        }
        _ = try await OracleDashboardProvider(serverVersion: nil).fetchMetrics { try server.execute($0) }
        #expect(!server.statements.contains { $0.contains("V_$CON_SYSMETRIC") })
    }

    @Test("A metric the account cannot read leaves the others, and only all of them failing is an error")
    func metricFailuresAreIndependent() async throws {
        let partial = Server { sql in
            if sql.contains("V_$INSTANCE") { return Self.result(["UPTIME"], [["60"]]) }
            throw Refusal()
        }
        let metrics = try await OracleDashboardProvider(serverVersion: nil).fetchMetrics { try partial.execute($0) }
        #expect(metrics.map { $0.id } == ["uptime"])

        let refused = Server { _ in throw Refusal() }
        await #expect(throws: Refusal.self) {
            _ = try await OracleDashboardProvider(serverVersion: nil).fetchMetrics { try refused.execute($0) }
        }
    }

    @Test("Every dictionary view is owner-qualified, so a current-schema object cannot stand in for it")
    func viewsAreOwnerQualified() {
        let statements = [
            OracleDashboardProvider.sessionsQuery,
            OracleDashboardProvider.slowQueriesQuery,
            OracleDashboardProvider.sessionCountQuery,
            OracleDashboardProvider.uptimeQuery,
        ] + OracleDashboardProvider.rateQueries
        for sql in statements {
            #expect(sql.range(of: #"(?<!SYS\.)\bG?V\$"#, options: .regularExpression) == nil, "\(sql)")
            #expect(sql.contains("SYS.V_$"), "\(sql)")
        }
    }
}
