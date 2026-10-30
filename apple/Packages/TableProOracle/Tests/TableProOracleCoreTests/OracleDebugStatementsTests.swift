import Foundation
@testable import TableProOracleCore
import Testing

struct OracleDebugStatementsTests {
    private let body = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)

    @Test func testPayloadRoundTripsNullsEmptyTextAndWideCharacters() throws {
        let fields: [String?] = [nil, "", "12:34", "Tiếng Việt 🇻🇳", "~", "a\nb"]
        let encoded = OracleDebugPayload.encode(fields)
        #expect(try OracleDebugPayload.parse(encoded) == fields)
        #expect(try OracleDebugPayload.parse(OracleDebugPayload.join(pieces: [String(encoded.prefix(7)), nil, String(encoded.dropFirst(7))]))
            == fields)
    }

    @Test func testAMalformedPayloadThrows() {
        #expect(throws: OracleDebugPayload.ParseError.self) { try OracleDebugPayload.parse("5:abc") }
        #expect(throws: OracleDebugPayload.ParseError.self) { try OracleDebugPayload.parse("x") }
    }

    // Measured: level 2 with PLSQL_DEBUG FALSE answers SET_BREAKPOINT with success and never stops.
    @Test func testReadinessFollowsTheMeasuredSettings() {
        #expect(OracleDebugStatements.readiness(fromRow: ["2", "TRUE"]) == .ready)
        #expect(OracleDebugStatements.readiness(fromRow: ["1", "FALSE"]) == .ready)
        #expect(OracleDebugStatements.readiness(fromRow: ["0", "FALSE"]) == .ready)
        #expect(OracleDebugStatements.readiness(fromRow: ["2", "FALSE"]) == .needsDebugCompile)
        #expect(OracleDebugStatements.readiness(fromRow: nil) == .notVisible)
    }

    @Test func testReadinessAsksForTheBodyOfAPackage() {
        let spec = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .package)
        #expect(OracleDebugStatements.readiness(of: spec).contains("TYPE = 'PACKAGE BODY'"))
        #expect(OracleDebugStatements.readiness(of: spec).contains("FROM SYS.ALL_PLSQL_OBJECT_SETTINGS"))
    }

    @Test func testMissingPrivilegesNameTheGrant() {
        #expect(OracleDebugStatements.missingPrivilege(fromRow: ["PROBE", "0", "0", "0"], unit: body)
            == .debugConnectSession(user: "PROBE"))
        #expect(OracleDebugStatements.missingPrivilege(fromRow: ["PROBE", "1", "0", "0"], unit: body) == nil)
        #expect(OracleDebugStatements.missingPrivilege(fromRow: ["NOACL", "1", "0", "0"], unit: body)
            == .debugOnObject(user: "NOACL"))
        #expect(OracleDebugStatements.missingPrivilege(fromRow: ["NOACL", "1", "0", "1"], unit: body) == nil)
        #expect(OracleDebugStatements.missingPrivilege(fromRow: ["NOACL", "1", "1", "0"], unit: body) == nil)
    }

    @Test func testEntryPointsGroupOverloadsAndReadTheResult() {
        let rows: [[String?]] = [
            ["ADD_TAX", "1", "1", "0", nil, "NUMBER", "OUT", "N", nil, nil, nil, nil],
            ["ADD_TAX", "1", "1", "1", "P_AMOUNT", "NUMBER", "IN", "N", nil, nil, nil, nil],
            ["ADD_TAX", "2", "2", "0", nil, "NUMBER", "OUT", "N", nil, nil, nil, nil],
            ["ADD_TAX", "2", "2", "1", "P_AMOUNT", "NUMBER", "IN", "N", nil, nil, nil, nil],
            ["ADD_TAX", "2", "2", "2", "P_RATE", "NUMBER", "IN", "N", nil, nil, nil, nil],
            ["RUN", "3", nil, "1", "P_N", "BINARY_INTEGER", "IN", "N", nil, nil, nil, "PLS_INTEGER"],
            ["RESET", "4", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil]
        ]
        let entries = OracleDebugStatements.parseEntryPoints(rows: rows, unit: body)
        #expect(entries.map(\.displayName) == [
            "ADD_TAX(P_AMOUNT NUMBER) RETURN NUMBER",
            "ADD_TAX(P_AMOUNT NUMBER, P_RATE NUMBER) RETURN NUMBER",
            "RUN(P_N PLS_INTEGER)",
            "RESET"
        ])
        #expect(entries[1].entry.identity == "PACKAGE BODY/PROBE/PKG_CALC/ADD_TAX/2")
        #expect(entries[3].parameters.isEmpty && entries[3].result == nil)
    }

    @Test func testInvocationNamesArgumentsAndLeavesDefaultsOut() throws {
        let entry = OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "F_CALC", kind: .function), subprogram: "F_CALC", subprogramID: 1),
            overload: nil,
            parameters: [
                OracleDebugParameter(name: "P_A", position: 1, dataType: "NUMBER", mode: .input, hasDefault: false),
                OracleDebugParameter(name: "P_B", position: 2, dataType: "VARCHAR2", mode: .input, hasDefault: true),
                OracleDebugParameter(name: "P_FLAG", position: 3, dataType: "PL/SQL BOOLEAN", mode: .input, hasDefault: true)
            ],
            result: OracleDebugParameter(name: "", position: 0, dataType: "NUMBER", mode: .output, hasDefault: false)
        )
        let invocation = try OracleDebugStatements.invocation(
            of: entry,
            arguments: ["P_A": .text("21"), "P_B": .defaultValue, "P_FLAG": .text("false")]
        )
        #expect(invocation.binds == [.text("21"), .text("false")])
        #expect(invocation.block.contains("  l_arg1 NUMBER;"))
        #expect(invocation.block.contains("  l_arg3 BOOLEAN;"))
        #expect(invocation.block.contains("  l_arg1 := TO_NUMBER(:1);"))
        #expect(invocation.block.contains("  l_arg3 := CASE UPPER(TRIM(:2)) WHEN 'TRUE' THEN TRUE"))
        #expect(invocation.block.contains("l_result := \"PROBE\".\"F_CALC\"(\"P_A\" => l_arg1, \"P_FLAG\" => l_arg3);"))
        #expect(!invocation.block.contains("\"P_B\""))
        #expect(invocation.block.contains("put('F_CALC');"))
        #expect(invocation.block.contains("OPEN :rows FOR"))
    }

    @Test func testOutParametersAreDeclaredPassedAndReported() throws {
        let entry = OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "P_WRITE", kind: .procedure), subprogram: "P_WRITE", subprogramID: 1),
            overload: nil,
            parameters: [
                OracleDebugParameter(name: "P_NOTE", position: 1, dataType: "VARCHAR2", mode: .input, hasDefault: false),
                OracleDebugParameter(name: "P_COUNT", position: 2, dataType: "NUMBER", mode: .output, hasDefault: false),
                OracleDebugParameter(name: "P_ROW", position: 3, dataType: "PL/SQL RECORD", mode: .inputOutput, hasDefault: false,
                                     typeOwner: "PROBE", typeName: "PKG", typeSubname: "REC_T")
            ],
            result: nil
        )
        let invocation = try OracleDebugStatements.invocation(of: entry, arguments: ["P_NOTE": .null, "P_ROW": .null])
        #expect(invocation.binds.isEmpty)
        #expect(invocation.block.contains("l_arg1 VARCHAR2(32767);"))
        #expect(invocation.block.contains("l_arg2 NUMBER;"))
        #expect(invocation.block.contains("l_arg3 \"PROBE\".\"PKG\".\"REC_T\";"))
        #expect(invocation.block.contains("\"PROBE\".\"P_WRITE\"(\"P_NOTE\" => l_arg1, \"P_COUNT\" => l_arg2, \"P_ROW\" => l_arg3);"))
        #expect(!invocation.block.contains("=> NULL"))
        #expect(invocation.block.contains("put('1');"))
        #expect(invocation.block.contains("put(TO_CHAR(l_arg2));"))
    }

    // Two overloads that differ only in the type of P_X: the typed local is what makes Oracle pick the chosen one.
    @Test func testEachOverloadIsCalledWithItsOwnTypes() throws {
        func overload(_ id: Int, _ type: String) -> OracleDebugEntryPoint {
            OracleDebugEntryPoint(
                entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "PKG_OVER", kind: .packageBody), subprogram: "SHOW", subprogramID: id),
                overload: String(id),
                parameters: [OracleDebugParameter(name: "P_X", position: 1, dataType: type, mode: .input, hasDefault: false)],
                result: nil
            )
        }
        let number = try OracleDebugStatements.invocation(of: overload(1, "NUMBER"), arguments: ["P_X": .text("5")])
        #expect(number.block.contains("  l_arg1 NUMBER;"))
        #expect(number.block.contains("  l_arg1 := TO_NUMBER(:1);"))
        #expect(number.block.contains("\"PROBE\".\"PKG_OVER\".\"SHOW\"(\"P_X\" => l_arg1);"))
        let text = try OracleDebugStatements.invocation(of: overload(2, "VARCHAR2"), arguments: ["P_X": .text("5")])
        #expect(text.block.contains("  l_arg1 VARCHAR2(32767);"))
        #expect(text.block.contains("  l_arg1 := :1;"))
        let null = try OracleDebugStatements.invocation(of: overload(2, "VARCHAR2"), arguments: ["P_X": .null])
        #expect(null.block.contains("  l_arg1 VARCHAR2(32767);"))
        #expect(!null.block.contains("l_arg1 :="))
        #expect(null.block.contains("(\"P_X\" => l_arg1);"))
    }

    @Test func testDateLikeTextConvertsExplicitly() throws {
        let entry = OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "P", kind: .procedure), subprogram: "P", subprogramID: 1),
            overload: nil,
            parameters: [
                OracleDebugParameter(name: "P_D", position: 1, dataType: "DATE", mode: .input, hasDefault: false),
                OracleDebugParameter(name: "P_T", position: 2, dataType: "TIMESTAMP WITH TIME ZONE", mode: .input, hasDefault: false),
                OracleDebugParameter(name: "P_I", position: 3, dataType: "INTERVAL DAY TO SECOND", mode: .input, hasDefault: false),
                OracleDebugParameter(name: "P_N", position: 4, dataType: "BINARY_INTEGER", mode: .input, hasDefault: false, plsType: "PLS_INTEGER")
            ],
            result: nil
        )
        let invocation = try OracleDebugStatements.invocation(
            of: entry,
            arguments: ["P_D": .text("2024-01-02"), "P_T": .text("x"), "P_I": .text("+00 01:00:00"), "P_N": .text("3")]
        )
        #expect(invocation.block.contains("l_arg1 := TO_DATE(:1);"))
        #expect(invocation.block.contains("l_arg2 := TO_TIMESTAMP_TZ(:2);"))
        #expect(invocation.block.contains("l_arg3 := TO_DSINTERVAL(:3);"))
        #expect(invocation.block.contains("l_arg4 PLS_INTEGER;"))
    }

    @Test func testTextCannotBePassedToACollection() {
        let entry = OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "P", kind: .procedure), subprogram: "P", subprogramID: 1),
            overload: nil,
            parameters: [OracleDebugParameter(name: "P_LIST", position: 1, dataType: "TABLE", mode: .input, hasDefault: false,
                                              typeOwner: "PROBE", typeName: "NUM_LIST")],
            result: nil
        )
        #expect(throws: OracleDebugStatements.InvocationError.unsupportedArgument(name: "P_LIST", typeName: "PROBE.NUM_LIST")) {
            try OracleDebugStatements.invocation(of: entry, arguments: ["P_LIST": .text("1,2")])
        }
    }

    @Test func testInvocationReportReadsOutputsAndLines() throws {
        let fields: [String?] = ["S", nil, "2", "F_CALC", "42", "P_COUNT", nil, "probe total=3.3", "second"]
        let report = try OracleDebugStatements.invocationReport(fromPayload: fields)
        #expect(report.succeeded)
        #expect(report.outputs.map(\.name) == ["F_CALC", "P_COUNT"])
        #expect(report.outputs.map(\.value) == ["42", nil])
        #expect(report.lines == ["probe total=3.3", "second"])
        let failed = try OracleDebugStatements.invocationReport(fromPayload: ["F", "ORA-01476: divisor is equal to zero", "0"])
        #expect(!failed.succeeded)
        #expect(failed.error == "ORA-01476: divisor is equal to zero")
    }

    @Test func testSourceKeepsAllSourceLineNumbers() {
        let text = OracleDebugStatements.assembleSource(rows: [
            (1, "package body pkg_calc as\n"),
            (3, "  function add_tax return number is\n"),
            (2, "  g_rate number := 0.1;\n"),
            (5, "end pkg_calc;")
        ])
        #expect(text == "package body pkg_calc as\n  g_rate number := 0.1;\n  function add_tax return number is\n\nend pkg_calc;")
    }

    @Test func testSourceDropsCRLFEndingsAndKeepsEveryCharacter() {
        let text = OracleDebugStatements.assembleSource(rows: [
            (1, "begin\r\n"),
            (2, "\r\n"),
            (3, "  x := 1;\r\n"),
            (4, "end;")
        ])
        #expect(text == "begin\n\n  x := 1;\nend;")
    }

    // The messages measured on 23.26 for each way the database can fail to connect back.
    @Test func testJDWPFailuresClassifyTheMeasuredErrors() {
        #expect(OracleDebugStatements.jdwpFailure(fromMessage: """
            ORA-24247: network access denied by access control list (ACL)
            ORA-06512: at "SYS.DBMS_DEBUG_JDWP", line 68
            """) == .accessControlList)
        let refused = "ORA-30683: failure establishing connection to debugger\nORA-30698: network connection failed: connection refused"
        #expect(OracleDebugStatements.jdwpFailure(fromMessage: refused) == .unreachable(refused))
        #expect(OracleDebugStatements.jdwpFailure(fromMessage: "ORA-01031: insufficient privileges\nORA-06512: at \"SYS.DBMS_DEBUG_JDWP\", line 68")
            == .missingPrivilege)
        #expect(OracleDebugStatements.jdwpFailure(fromMessage: "ORA-06576: not a valid function or procedure name: DBMS_DEBUG_JDWP")
            == .packageUnavailable)
        #expect(OracleDebugStatements.errorCodes(in: "ORA-30683: x\nORA-30698: y") == [30_683, 30_698])
    }

    @Test func testPortRanges() {
        #expect(OracleDebugStatements.ports(from: "4000-4999") == 4_000...4_999)
        #expect(OracleDebugStatements.ports(from: "4000 - 4999") == 4_000...4_999)
        #expect(OracleDebugStatements.ports(from: " 15400 ") == 15_400...15_400)
        #expect(OracleDebugStatements.ports(from: "5000-4000") == nil)
        #expect(OracleDebugStatements.ports(from: "abc") == nil)
        #expect(OracleDebugStatements.ports(from: "0") == nil)
        #expect(OracleDebugStatements.ports(from: "4000-") == nil)
    }

    // A DBA's ACEs for ports 4000 and 4005 are not the range between them: a list is refused, never read as 4000-4005.
    @Test func testAPortListIsRefused() {
        #expect(OracleDebugStatements.ports(from: "4000, 4005") == nil)
        #expect(OracleDebugStatements.ports(from: "4000 4005") == nil)
        #expect(OracleDebugStatements.ports(from: "4000-4005-4010") == nil)
    }

    @Test func testABFILEPassesAsATypedNullAndRefusesText() throws {
        let entry = OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "P", kind: .procedure), subprogram: "P", subprogramID: 1),
            overload: nil,
            parameters: [OracleDebugParameter(name: "F", position: 1, dataType: "BFILE", mode: .input, hasDefault: false)],
            result: nil
        )
        let null = try OracleDebugStatements.invocation(of: entry, arguments: ["F": .null])
        #expect(null.block.contains("  l_arg1 BFILE;"))
        #expect(null.block.contains("(\"F\" => l_arg1);"))
        #expect(throws: OracleDebugStatements.InvocationError.unsupportedArgument(name: "F", typeName: "BFILE")) {
            try OracleDebugStatements.invocation(of: entry, arguments: ["F": .text("x")])
        }
    }

    // A type with no name to declare cannot be passed at all, not even as NULL.
    @Test func testAnUndeclarableTypeIsToldApartFromText() {
        let entry = OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "P", kind: .procedure), subprogram: "P", subprogramID: 1),
            overload: nil,
            parameters: [OracleDebugParameter(name: "T", position: 1, dataType: "PL/SQL TABLE", mode: .input, hasDefault: false)],
            result: nil
        )
        #expect(throws: OracleDebugStatements.InvocationError.undeclarableArgument(name: "T", typeName: "PL/SQL TABLE")) {
            try OracleDebugStatements.invocation(of: entry, arguments: ["T": .null])
        }
    }

    @Test func testConnectBlockBindsHostAndPortThroughACall() {
        #expect(OracleDebugStatements.jdwpConnect.contains("'CALL SYS.DBMS_DEBUG_JDWP.CONNECT_TCP(:1, :2)' USING :1, :2"))
    }
}

struct OracleDebugProtocolDecisionTests {
    @Test func testTheFirstChoiceFollowsThePreferenceAndTheHost() {
        #expect(OracleDebugProtocolDecision.initial(preference: .automatic, host: "192.168.1.20") == .jdwp)
        #expect(OracleDebugProtocolDecision.initial(preference: .automatic, host: " ") == .dbmsDebug(.noDebuggerHost))
        #expect(OracleDebugProtocolDecision.initial(preference: .dbmsDebug, host: "192.168.1.20") == .dbmsDebug(.chosen))
        #expect(OracleDebugProtocolDecision.initial(preference: .jdwp, host: "192.168.1.20") == .jdwp)
        // Behind a tunnel the host starts empty; explicit DBMS_DEBUG_JDWP is refused before any session opens.
        #expect(OracleDebugProtocolDecision.initial(preference: .jdwp, host: " ") == .fail)
    }

    @Test func testAutomaticFallsBackOnTheNetworkFailures() {
        let fallsBack: [OracleJDWPFailure] = [
            .accessControlList, .unreachable("ORA-30683"), .packageUnavailable, .timedOut, .noFreePort, .handshakeFailed
        ]
        for failure in fallsBack {
            #expect(OracleDebugProtocolDecision.afterJDWPFailure(failure, preference: .automatic) == .fallBack)
            #expect(OracleDebugProtocolDecision.afterJDWPFailure(failure, preference: .jdwp) == .fail)
        }
    }

    // DBMS_DEBUG needs the same DEBUG CONNECT SESSION (ORA-01031 from both, measured).
    @Test func testAPrivilegeOrUnknownFailureIsFinal() {
        #expect(OracleDebugProtocolDecision.afterJDWPFailure(.missingPrivilege, preference: .automatic) == .fail)
        #expect(OracleDebugProtocolDecision.afterJDWPFailure(.noDebuggerHost, preference: .automatic) == .fail)
        #expect(OracleDebugProtocolDecision.afterJDWPFailure(.other("ORA-00600"), preference: .automatic) == .fail)
    }
}
