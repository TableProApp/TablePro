import Foundation
@testable import TableProOracleCore
import Testing

struct OracleDBMSDebugStatementsTests {
    private typealias Statements = OracleDBMSDebugStatements

    // continue at the breakpoint on ADD_TAX line 6, called from RUN line 14 (the lane's measured stop).
    @Test func testAPauseReadsTheRuntimeRecordAndTheBacktrace() throws {
        let fields: [String?] = [
            "0", "3", "0", "6", "1",
            "3",
            nil, nil, "0", "0", "1", nil,
            "PROBE", "PKG_CALC", "2", "11", "14", "RUN",
            "PROBE", "PKG_CALC", "2", "11", "6", "ADD_TAX"
        ]
        let event = try Statements.event(fromPayload: fields)
        #expect(event.isPause)
        #expect(!event.timedOut)
        #expect(event.reason == Statements.Reason.breakpoint)
        #expect(event.line == 6)
        #expect(event.breakpoint == 1)
        #expect(event.backtrace.count == 3)
        #expect(event.backtrace[0].unit == nil)
        #expect(event.backtrace[2].unit == OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody))
        #expect(event.backtrace[1].entryPoint == "RUN")
    }

    @Test func testTerminationAndTimeoutCarryNoBacktrace() throws {
        let ended = try Statements.event(fromPayload: ["0", "25", "1", nil, nil, "0"])
        #expect(ended.terminated)
        #expect(!ended.isPause)
        let waiting = try Statements.event(fromPayload: ["31", "2", "0", nil, nil, "0"])
        #expect(waiting.timedOut)
        #expect(!waiting.isPause)
    }

    @Test func testResumeUsesTheMeasuredBreakFlags() {
        #expect(Statements.resume(flags: Statements.BreakFlags.anyReturn).contains("SYS.DBMS_DEBUG.CONTINUE(l_info, 512, 14)"))
        #expect(Statements.resume(flags: Statements.BreakFlags.nextLine).contains("CONTINUE(l_info, 32, 14)"))
        #expect(Statements.resume(flags: Statements.BreakFlags.anyCall).contains("CONTINUE(l_info, 12, 14)"))
        #expect(Statements.resume(flags: Statements.BreakFlags.abortExecution).contains("CONTINUE(l_info, 8192, 14)"))
        #expect(Statements.resume(flags: nil).contains("SYS.DBMS_DEBUG.SYNCHRONIZE(l_info, 14)"))
        // Asking a terminated program for its backtrace raises inside SYS.PBREAK.
        #expect(Statements.resume(flags: nil).contains("IF l_status = 0 AND NVL(l_info.Terminated, 0) = 0 THEN"))
    }

    // The target aborts itself when the supervisor goes quiet; without this a crashed app left it in `pipe get`.
    @Test func testTheTargetAbortsOnTimeoutAndIsPinged() {
        let setup = Statements.targetSetup(debugID: "TPX")
        #expect(setup.binds == [.text("TPX")])
        #expect(setup.block.contains("SET_TIMEOUT_BEHAVIOUR(3)"))
        #expect(setup.block.contains("SET_TIMEOUT(30)"))
        #expect(setup.block.contains("'CALL SYS.DBMS_DEBUG.DEBUG_ON()'"))
        #expect(Statements.pingIntervalSeconds * 2 < Statements.targetTimeoutSeconds)
        #expect(Statements.supervisorTimeoutSeconds < Statements.pingIntervalSeconds)
    }

    // GET_LINE_MAP for PROBE.PKG_CALC's body answered maxline 22 and EEFF3F.
    @Test func testTheMeasuredLineMapDecodes() throws {
        #expect(Statements.executableLines(hexMap: "EEFF3F", maxLine: 22)
            == [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21])
        #expect(try Statements.executableLines(fromPayload: ["0", "8", "FE"]) == [1, 2, 3, 4, 5, 6, 7])
        #expect(try Statements.executableLines(fromPayload: ["16", nil, nil]) == nil)
    }

    @Test func testValueStatusesMapToValues() throws {
        let answers = try Statements.valueAnswers(fromPayload: ["0", "1", "32", nil, "18", nil, "3", nil, "40", nil], count: 5)
        #expect(answers.map { Statements.value(status: $0.status, text: $0.value) } == [
            .scalar("1"), .scalar(nil), .collection(count: nil), nil, .scalar(nil)
        ])
    }

    // Read before DEBUG_ON: the target's SID and SERIAL#, which Stop needs to end a routine running between breakpoints.
    @Test func testTheTargetSessionIsIdentifiedForAKill() {
        #expect(Statements.sessionIdentity(fromRow: ["213", "28648", "2"])
            == OracleDebugSessionIdentity(sid: 213, serial: 28_648, instance: 2))
        #expect(Statements.sessionIdentity(fromRow: ["213", nil, "1"]) == OracleDebugSessionIdentity(sid: 213, serial: nil, instance: 1))
        #expect(Statements.sessionIdentity(fromRow: [nil, nil, "1"]) == nil)
        #expect(Statements.killSession(OracleDebugSessionIdentity(sid: 213, serial: 28_648))
            == "ALTER SYSTEM KILL SESSION '213,28648' IMMEDIATE")
        #expect(Statements.killSession(OracleDebugSessionIdentity(sid: 213, serial: 28_648, instance: 2))
            == "ALTER SYSTEM KILL SESSION '213,28648,@2' IMMEDIATE")
        #expect(Statements.sessionIdentityQueries.allSatisfy { $0.contains("SYS_CONTEXT('USERENV', 'INSTANCE')") })
        #expect(Statements.killSession(OracleDebugSessionIdentity(sid: 213, serial: nil)) == nil)
        #expect(Statements.sessionIdentityQueries.first?.contains("DBMS_DEBUG_JDWP.CURRENT_SESSION_SERIAL") == true)
    }

    @Test func testBreakpointsAndValuesQuoteNames() {
        let unit = OracleDebugUnit(owner: "PROBE", name: "O'NEIL", kind: .packageBody)
        let set = Statements.setBreakpoint(unit: unit, line: 6)
        #expect(set.contains("l_program.Namespace := 2;"))
        #expect(set.contains("l_program.Name := 'O''NEIL';"))
        #expect(set.contains("SET_BREAKPOINT(l_program, 6, l_number)"))
        let values = Statements.values([
            .init(name: "P_AMOUNT", frame: 0),
            .init(name: "G_RATE", package: OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody))
        ])
        #expect(values.block.contains("GET_VALUE(:1, 0, l_value, NULL)"))
        #expect(values.block.contains("GET_VALUE(:2, l_handle, l_value, NULL)"))
        #expect(values.binds == [.text("P_AMOUNT"), .text("G_RATE")])
        #expect(Statements.deleteBreakpoints([]).contains("NULL;"))
    }

    // A quoted declaration is asked for quoted, so GET_VALUE reads one identifier, and the name stays a bind.
    @Test func testQuotedVariableNamesAreBoundQuoted() {
        let scan = OraclePLSQLDeclarationScan(source: """
            procedure p is
              "a.b" number;
              "lower" number;
              "with space" number;
              l_plain number;
            begin
              null;
            end p;
            """)
        let requests = scan.candidates(atLine: 7).map { Statements.ValueRequest(name: $0.lookupName, frame: 0) }
        let values = Statements.values(requests)
        #expect(values.binds == [.text("\"a.b\""), .text("\"lower\""), .text("\"with space\""), .text("L_PLAIN")])
        #expect(values.block.contains("GET_VALUE(:4, 0, l_value, NULL)"))
        #expect(!values.block.contains("a.b") && !values.block.contains("lower") && !values.block.contains("L_PLAIN"))
    }

    // Every block that declares the payload helpers declares them last: PL/SQL wants items before subprograms.
    @Test func testPayloadHelpersComeLastInEachDeclareSection() throws {
        let unit = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)
        for block in [Statements.resume(flags: 0), Statements.setBreakpoint(unit: unit, line: 1),
                      Statements.lineMap(of: unit), Statements.values([.init(name: "X", frame: 0)]).block] {
            let helper = try #require(block.range(of: "PROCEDURE put"))
            let lastDeclaration = try #require(block.range(of: "l_status BINARY_INTEGER;"))
            #expect(lastDeclaration.lowerBound < helper.lowerBound)
        }
    }
}
