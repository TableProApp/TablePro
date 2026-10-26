//
//  PostgreSQLRoutineDebugProtocolTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// Replies, rows and errors below are copied from PostgreSQL 17.11 with pldebugger 1.10
// (apple/scripts/probes/check-pldebugger-session.sh).
struct PostgreSQLRoutineDebugProtocolTests {
    private static func routine(_ row: [String?], identity: String = "16433") -> PostgreSQLDebugRoutine {
        PostgreSQLDebugRoutine(row: row, identity: identity)
    }

    private static let orderTotal = routine([
        "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "order_total",
        "qty integer, unit_price numeric", "f", "f", "{integer,numeric}", "{qty,unit_price}", nil, "0"
    ])

    private static let logNote = routine([
        "postgres", "public", "t", "t", "t", "p", "v", "plpgsql", "public", "log_note",
        "IN msg text, INOUT n integer, IN label text", "t", "f", "{text,integer,text}", "{msg,n,label}",
        "{i,b,i}", "2"
    ], identity: "16434")

    private static let pair = routine([
        "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "pair",
        "a integer, OUT x integer, OUT y text", "t", "f", "{integer,integer,text}", "{a,x,y}", "{i,o,o}", "0"
    ], identity: "16435")

    private static let anonymous = routine([
        "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "anon",
        "integer, integer", "t", "f", "{integer,integer}", nil, nil, "1"
    ], identity: "16436")

    private static let totalOf = routine([
        "postgres", "public", "t", "t", "t", "f", "s", "plpgsql", "public", "total_of",
        "VARIADIC nums integer[]", "f", "f", "{integer[]}", "{nums}", "{v}", "0"
    ], identity: "16437")

    private static func argument(_ name: String, _ value: PluginDebugArgumentValue) -> PluginDebugArgument {
        PluginDebugArgument(parameterName: name, value: value)
    }

    private static func result(columns: [String]) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns,
            columnTypeNames: columns.map { _ in "numeric" },
            rows: columns.isEmpty ? [] : [["33.0"]],
            rowsAffected: 0,
            executionTime: 0
        )
    }

    // MARK: - Notices

    @Test("The PLDBGBREAK notice names the backend the proxy attaches to")
    func breakNoticeParses() {
        #expect(PostgreSQLRoutineDebugProtocol.debuggerPort(inNotice: "PLDBGBREAK:12") == 12)
        #expect(PostgreSQLRoutineDebugProtocol.debuggerPort(inNotice: " PLDBGBREAK:3\n") == 3)
    }

    @Test("Any other notice is routine output, not a port")
    func otherNoticesAreOutput() {
        #expect(PostgreSQLRoutineDebugProtocol.debuggerPort(inNotice: "rows now 2") == nil)
        #expect(PostgreSQLRoutineDebugProtocol.debuggerPort(inNotice: "PLDBGBREAK:") == nil)
        #expect(PostgreSQLRoutineDebugProtocol.debuggerPort(inNotice: "said PLDBGBREAK:4") == nil)
    }

    // MARK: - Lines

    @Test("A stop's reported line is one past the source line")
    func stopLineIsShifted() {
        let stop = PostgreSQLRoutineDebugProtocol.location(
            fromBreakpointRow: ["16431", "9", "order_total(integer,numeric)"]
        )
        #expect(stop?.line == 8)
        #expect(stop?.unit.identity == "16431")
        #expect(stop?.unit.displayName == "order_total(integer,numeric)")
    }

    @Test("A stack frame's line is the source line as is")
    func stackLineIsNotShifted() {
        let frame = PostgreSQLRoutineDebugProtocol.frame(
            fromStackRow: ["1", "order_total(integer,numeric)", "16431", "8", "qty=3, unit_price=10"]
        )
        #expect(frame?.level == 1)
        #expect(frame?.location?.line == 8)
        #expect(frame?.location?.unit.identity == "16431")
        #expect(frame?.arguments == "qty=3, unit_price=10")
    }

    @Test("A reply without a stop means the target left the debugger")
    func emptyStopIsNoLocation() {
        #expect(PostgreSQLRoutineDebugProtocol.location(fromBreakpointRow: []) == nil)
        #expect(PostgreSQLRoutineDebugProtocol.location(fromBreakpointRow: [nil, nil, nil]) == nil)
    }

    @Test("Breakpoints are set on the source line, unshifted")
    func breakpointLineIsNotShifted() {
        let statement = PostgreSQLRoutineDebugProtocol.setBreakpointStatement(
            extensionSchema: "public",
            session: 1,
            oid: 16_433,
            line: 12
        )
        #expect(statement == "SELECT \"public\".pldbg_set_breakpoint(1, '16433'::pg_catalog.oid, 12)")
    }

    // MARK: - Variables

    @Test("Variable classes map to argument, local and package")
    func variableKinds() {
        let argument = PostgreSQLRoutineDebugProtocol.variable(
            fromRow: ["qty", "A", "0", "t", "f", "f", "integer", "3"]
        )
        let local = PostgreSQLRoutineDebugProtocol.variable(
            fromRow: ["subtotal", "L", "3", "t", "f", "f", "numeric", "0"]
        )
        let package = PostgreSQLRoutineDebugProtocol.variable(
            fromRow: ["counter", "P", "0", "t", "t", "f", "integer", "1"]
        )
        #expect(argument?.kind == .argument)
        #expect(argument?.typeName == "integer")
        #expect(argument?.value == "3")
        #expect(local?.kind == .local)
        #expect(package?.kind == .package)
        #expect(package?.isConstant == true)
        #expect(local?.isConstant == false)
    }

    @Test("The text NULL pldebugger sends for a null value reads as SQL NULL")
    func nullTextIsNull() {
        let variable = PostgreSQLRoutineDebugProtocol.variable(
            fromRow: ["total", "L", "4", "t", "f", "f", "numeric", "NULL"]
        )
        #expect(variable != nil)
        #expect(variable?.value == nil)
    }

    // MARK: - The call

    @Test("A function runs as SELECT * FROM with each argument bound and cast to its declared type")
    func functionCall() throws {
        let call = try PostgreSQLRoutineDebugProtocol.call(
            for: Self.orderTotal,
            arguments: [Self.argument("qty", .text("3")), Self.argument("unit_price", .text("10"))]
        )
        #expect(call.sql == "SELECT * FROM \"public\".\"order_total\"($1::integer, $2::numeric)")
        #expect(call.parameters == [.text("3"), .text("10")])
    }

    @Test("A procedure runs as CALL")
    func procedureCall() throws {
        let call = try PostgreSQLRoutineDebugProtocol.call(
            for: Self.logNote,
            arguments: [
                Self.argument("msg", .text("hello")),
                Self.argument("n", .defaultValue),
                Self.argument("label", .defaultValue)
            ]
        )
        #expect(call.sql == "CALL \"public\".\"log_note\"($1::text)")
        #expect(call.parameters == [.text("hello")])
    }

    @Test("An argument after one left to its default is passed by name")
    func argumentAfterDefaultIsNamed() throws {
        let call = try PostgreSQLRoutineDebugProtocol.call(
            for: Self.logNote,
            arguments: [
                Self.argument("msg", .text("hello")),
                Self.argument("n", .defaultValue),
                Self.argument("label", .text("-lbl"))
            ]
        )
        #expect(call.sql == "CALL \"public\".\"log_note\"($1::text, \"label\" => $2::text)")
        #expect(call.parameters == [.text("hello"), .text("-lbl")])
    }

    @Test("A function returning a bare record is selected as a value")
    func recordFunctionCall() throws {
        let call = try PostgreSQLRoutineDebugProtocol.call(
            for: Self.anonymous,
            arguments: [Self.argument("$1", .text("7")), Self.argument("$2", .defaultValue)]
        )
        #expect(call.sql == "SELECT \"public\".\"anon\"($1::integer)")
    }

    @Test("A function with OUT parameters keeps SELECT * FROM and passes only its inputs")
    func outParametersAreNotPassed() throws {
        let call = try PostgreSQLRoutineDebugProtocol.call(for: Self.pair, arguments: [Self.argument("a", .text("4"))])
        #expect(call.sql == "SELECT * FROM \"public\".\"pair\"($1::integer)")
    }

    @Test("A variadic parameter takes its array with VARIADIC")
    func variadicCall() throws {
        let call = try PostgreSQLRoutineDebugProtocol.call(
            for: Self.totalOf,
            arguments: [Self.argument("nums", .text("{1,2,3}"))]
        )
        #expect(call.sql == "SELECT * FROM \"public\".\"total_of\"(VARIADIC $1::integer[])")
    }

    @Test("NULL is bound as a null parameter, not as text")
    func nullArgument() throws {
        let call = try PostgreSQLRoutineDebugProtocol.call(
            for: Self.orderTotal,
            arguments: [Self.argument("qty", .null), Self.argument("unit_price", .text("1"))]
        )
        #expect(call.parameters == [.null, .text("1")])
    }

    @Test("DEFAULT on a parameter without a default is refused")
    func defaultWithoutDefaultIsRefused() {
        #expect(throws: PostgreSQLRoutineDebugError.noDefault(parameter: "qty")) {
            try PostgreSQLRoutineDebugProtocol.call(
                for: Self.orderTotal,
                arguments: [Self.argument("qty", .defaultValue), Self.argument("unit_price", .text("1"))]
            )
        }
    }

    @Test("An unnamed parameter cannot follow one left to its default")
    func unnamedAfterDefaultIsRefused() {
        let routine = Self.routine([
            "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "f",
            "integer, integer", "f", "f", "{integer,integer}", nil, nil, "2"
        ])
        #expect(throws: PostgreSQLRoutineDebugError.defaultNotSkippable(parameter: "$1")) {
            try PostgreSQLRoutineDebugProtocol.call(
                for: routine,
                arguments: [Self.argument("$1", .defaultValue), Self.argument("$2", .text("1"))]
            )
        }
    }

    @Test("A procedure's OUT parameter gets a typed NULL placeholder")
    func procedureOutParameter() throws {
        let routine = Self.routine([
            "postgres", "public", "t", "t", "t", "p", "v", "plpgsql", "public", "p",
            "IN a integer, OUT b text", "t", "f", "{integer,text}", "{a,b}", "{i,o}", "0"
        ])
        let call = try PostgreSQLRoutineDebugProtocol.call(for: routine, arguments: [Self.argument("a", .text("1"))])
        #expect(call.sql == "CALL \"public\".\"p\"($1::integer, NULL::text)")
    }

    // MARK: - The routine

    @Test("Catalog arrays become parameters with modes and trailing defaults")
    func parametersFromCatalog() {
        let parameters = Self.logNote.parameters
        let names = parameters.map { $0.name }
        let modes = parameters.map { $0.mode }
        let defaults = parameters.map { $0.hasDefault }
        let types = parameters.map { $0.typeName }
        #expect(names == ["msg", "n", "label"])
        #expect(modes == [.input, .inputOutput, .input])
        #expect(defaults == [false, true, true])
        #expect(types == ["text", "integer", "text"])
    }

    @Test("An unnamed parameter is named by its position")
    func unnamedParameters() {
        let names = Self.anonymous.parameters.map { $0.name }
        let defaults = Self.anonymous.parameters.map { $0.hasDefault }
        #expect(names == ["$1", "$2"])
        #expect(defaults == [false, true])
    }

    @Test("The entry point's identity is the routine's oid")
    func entryIdentityIsTheOid() {
        #expect(Self.orderTotal.entryPoint.identity == "16433")
        #expect(PostgreSQLRoutineDebugProtocol.oid(inIdentity: "16433") == 16_433)
        #expect(PostgreSQLRoutineDebugProtocol.oid(inIdentity: "16433:w") == nil)
        #expect(PostgreSQLRoutineDebugProtocol.oid(inIdentity: "order_total") == nil)
    }

    @Test("A transaction startup commands left open is rolled back before the call")
    func startupTransactionIsRolledBack() {
        #expect(!PostgreSQLRoutineDebugProtocol.endsStartupTransaction(.idle))
        #expect(PostgreSQLRoutineDebugProtocol.endsStartupTransaction(.inTransaction))
        #expect(PostgreSQLRoutineDebugProtocol.endsStartupTransaction(.abortedTransaction))
        #expect(PostgreSQLRoutineDebugProtocol.endsStartupTransaction(.unknown))
    }

    @Test("A missing extension the server offers asks for CREATE EXTENSION in this database")
    func extensionMissing() {
        let routine = Self.routine([
            "noext", nil, "t", "t", "t", "f", "v", "plpgsql", "public", "f", "", "f", "f", "{}", nil, nil, "0"
        ])
        #expect(throws: PostgreSQLRoutineDebugError.extensionMissing(database: "noext")) {
            try routine.debuggerSchema()
        }
    }

    @Test("A server without the pldebugger package says so")
    func serverPackageMissing() {
        let routine = Self.routine([
            "postgres", nil, "f", "t", "t", "f", "v", "plpgsql", "public", "f", "", "f", "f", "{}", nil, nil, "0"
        ])
        #expect(throws: PostgreSQLRoutineDebugError.serverPackageMissing) {
            try routine.debuggerSchema()
        }
    }

    @Test("Only the owner or a superuser may debug")
    func notOwner() {
        let routine = Self.routine([
            "postgres", "public", "t", "t", "f", "f", "v", "plpgsql", "public", "order_total",
            "qty integer, unit_price numeric", "f", "f", "{integer,numeric}", "{qty,unit_price}", nil, "0"
        ])
        #expect(throws: PostgreSQLRoutineDebugError.notOwner(routine: "order_total(qty integer, unit_price numeric)")) {
            try routine.debuggerSchema()
        }
    }

    @Test("A trigger function or another language cannot be debugged")
    func notDebuggable() {
        let trigger = Self.routine([
            "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "trg_fn", "", "f", "t", "{}", nil, nil,
            "0"
        ])
        let sql = Self.routine([
            "postgres", "public", "t", "t", "t", "f", "v", "sql", "public", "f", "", "f", "f", "{}", nil, nil, "0"
        ])
        #expect(throws: PostgreSQLRoutineDebugError.notDebuggable) { try trigger.debuggerSchema() }
        #expect(throws: PostgreSQLRoutineDebugError.notDebuggable) { try sql.debuggerSchema() }
    }

    @Test("A routine taking a polymorphic or record argument is refused before the start")
    func pseudoTypeArgumentIsRefused() {
        let routine = Self.routine([
            "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "poly_elem", "a anyelement", "f", "f",
            "{anyelement}", "{a}", nil, "0", "t"
        ])
        #expect(throws: PostgreSQLRoutineDebugError.pseudoTypeParameter) { try routine.debuggerSchema() }
    }

    @Test("Polymorphic, \"any\" and record arguments are found in a signature; a parameter named like one is not")
    func signatureClassification() {
        let refused = [
            "(a anyelement)", "(VARIADIC \"any\")", "(x anyarray, y integer)", "(anycompatible, anycompatible)",
            "(a anycompatiblearray, b integer)", "(r record)", "(IN v anynonarray)", "(e anyenum)", "(r anyrange)",
            "(m anymultirange)", "(rs record[])"
        ]
        let offered = [
            "(qty integer, unit_price numeric)", "(anyelement integer)", "(\"my, record\" integer)",
            "(IN msg text, INOUT n integer, IN label text)", "()", "(VARIADIC nums integer[])",
            "(b timestamp with time zone)"
        ]
        for signature in refused {
            #expect(PostgreSQLRoutineDebugProtocol.signatureTakesPseudoType(signature), "\(signature)")
        }
        for signature in offered {
            #expect(!PostgreSQLRoutineDebugProtocol.signatureTakesPseudoType(signature), "\(signature)")
        }
        #expect(!PostgreSQLRoutineDebugProtocol.signatureTakesPseudoType(nil))
    }

    @Test("A routine whose own client_min_messages hides notices, or whose transaction_timeout is set, is refused")
    func blockingRoutineSettings() {
        #expect(
            PostgreSQLRoutineDebugProtocol.blockingSetting(in: ["client_min_messages=warning"])
                == .hidesDebuggerNotice(value: "warning")
        )
        #expect(
            PostgreSQLRoutineDebugProtocol.blockingSetting(in: ["search_path=app", "client_min_messages=ERROR"])
                == .hidesDebuggerNotice(value: "ERROR")
        )
        #expect(
            PostgreSQLRoutineDebugProtocol.blockingSetting(in: ["transaction_timeout=2s"])
                == .limitsTransactionTime(value: "2s")
        )
        for allowed in [
            "client_min_messages=notice", "client_min_messages=log", "client_min_messages=debug1",
            "transaction_timeout=0", "transaction_timeout=0ms", "search_path=app, public", "work_mem=64MB"
        ] {
            #expect(PostgreSQLRoutineDebugProtocol.blockingSetting(in: [allowed]) == nil, "\(allowed)")
        }
    }

    @Test("prepareDebug refuses a routine whose settings would stop the debugger")
    func blockingSettingRefusesPrepare() {
        let routine = Self.routine([
            "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "quiet", "x integer", "f", "f",
            "{integer}", "{x}", nil, "0", "f", "{client_min_messages=warning}"
        ])
        #expect(throws: PostgreSQLRoutineDebugError.hidesDebuggerNotice(value: "warning")) {
            try routine.debuggerSchema()
        }
    }

    @Test("char(n) and bit(n) arguments are cast to their unlimited forms so nothing is cut")
    func characterAndBitKeepTheirLength() throws {
        #expect(PostgreSQLRoutineDebugProtocol.castTypeName("character") == "pg_catalog.bpchar")
        #expect(PostgreSQLRoutineDebugProtocol.castTypeName("character[]") == "pg_catalog.bpchar[]")
        #expect(PostgreSQLRoutineDebugProtocol.castTypeName("bit") == "pg_catalog.varbit")
        #expect(PostgreSQLRoutineDebugProtocol.castTypeName("bit[]") == "pg_catalog.varbit[]")
        #expect(PostgreSQLRoutineDebugProtocol.castTypeName("character varying") == "character varying")
        #expect(PostgreSQLRoutineDebugProtocol.castTypeName("\"char\"") == "\"char\"")
        let routine = Self.routine([
            "postgres", "public", "t", "t", "t", "f", "v", "plpgsql", "public", "codes",
            "code character, flags bit, many character[]", "f", "f", "{character,bit,character[]}",
            "{code,flags,many}", nil, "0", "f", nil
        ])
        let call = try PostgreSQLRoutineDebugProtocol.call(
            for: routine,
            arguments: [
                Self.argument("code", .text("ABC")),
                Self.argument("flags", .text("101")),
                Self.argument("many", .text("{XY,ZW}"))
            ]
        )
        #expect(
            call.sql
                == "SELECT * FROM \"public\".\"codes\"($1::pg_catalog.bpchar, $2::pg_catalog.varbit, $3::pg_catalog.bpchar[])"
        )
    }

    @Test("A polymorphic routine is not offered for debugging")
    func polymorphicRoutineIsNotATarget() {
        let routine = PluginRoutineInfo(
            name: "poly_elem",
            kind: .function,
            returnType: "anyelement",
            language: "plpgsql",
            argumentSignature: "(a anyelement)",
            identity: "16440"
        )
        #expect(PostgreSQLRoutineDebugProtocol.target(for: routine) == nil)
    }

    @Test("The extension's schema qualifies every pldbgapi call")
    func extensionSchemaQualifiesCalls() throws {
        let schema = try Self.orderTotal.debuggerSchema()
        #expect(schema == "public")
        #expect(
            PostgreSQLRoutineDebugProtocol.stepStatement(.continueExecution, extensionSchema: "dbg\"x", session: 1)
                == "SELECT func, linenumber, targetname FROM \"dbg\"\"x\".pldbg_continue(1)"
        )
    }

    @Test("Step Out has no pldbgapi call")
    func noStepOut() {
        #expect(PostgreSQLRoutineDebugProtocol.stepStatement(.stepOut, extensionSchema: "public", session: 1) == nil)
        #expect(!PostgreSQLRoutineDebugProtocol.supportedCommands.contains(.stepOut))
    }

    // MARK: - Targets

    @Test("A PL/pgSQL function or procedure is a debug target named with its arguments")
    func plpgsqlRoutineIsTarget() {
        let routine = PluginRoutineInfo(
            name: "order_total",
            kind: .function,
            schema: "public",
            returnType: "numeric",
            language: "plpgsql",
            argumentSignature: "(qty integer, unit_price numeric)",
            identity: "16433"
        )
        let target = PostgreSQLRoutineDebugProtocol.target(for: routine)
        #expect(target?.identity == "16433")
        #expect(target?.name == "order_total(qty integer, unit_price numeric)")
        #expect(target?.schema == "public")
    }

    @Test("A routine in another language, a trigger function or one without an oid is not a target")
    func otherRoutinesAreNotTargets() {
        let sql = PluginRoutineInfo(name: "f", kind: .function, language: "sql", identity: "1")
        let trigger = PluginRoutineInfo(
            name: "trg_fn", kind: .function, returnType: "trigger", language: "plpgsql", identity: "2"
        )
        let noOid = PluginRoutineInfo(name: "f", kind: .function, language: "plpgsql", identity: nil)
        #expect(PostgreSQLRoutineDebugProtocol.target(for: sql) == nil)
        #expect(PostgreSQLRoutineDebugProtocol.target(for: trigger) == nil)
        #expect(PostgreSQLRoutineDebugProtocol.target(for: noOid) == nil)
    }

    // MARK: - Sessions

    @Test("Both sessions turn their timeouts off, and the target lets the port notice through")
    func sessionSettings() {
        #expect(
            PostgreSQLRoutineDebugProtocol.sessionSettings(serverVersion: 170_011, isTarget: true)
                == [
                    "SET statement_timeout = 0",
                    "SET idle_session_timeout = 0",
                    "SET transaction_timeout = 0",
                    "SET client_min_messages = notice"
                ]
        )
        #expect(
            PostgreSQLRoutineDebugProtocol.sessionSettings(serverVersion: 130_000, isTarget: false)
                == ["SET statement_timeout = 0"]
        )
    }

    @Test("transaction_timeout, new in PostgreSQL 17, is turned off only on servers that have it")
    func transactionTimeoutVersionGate() {
        let seventeen = PostgreSQLRoutineDebugProtocol.sessionSettings(serverVersion: 170_000, isTarget: false)
        let sixteen = PostgreSQLRoutineDebugProtocol.sessionSettings(serverVersion: 160_004, isTarget: false)
        #expect(seventeen == ["SET statement_timeout = 0", "SET idle_session_timeout = 0", "SET transaction_timeout = 0"])
        #expect(sixteen == ["SET statement_timeout = 0", "SET idle_session_timeout = 0"])
    }

    // MARK: - Cancelling a start

    @Test("A start cancelled before the routine is entered cancels the target's call")
    func cancelBeforeEntryCancelsTheCall() {
        #expect(PostgreSQLRoutineDebugProtocol.startCancellation(portDelivered: false, callEnded: false) == .cancelCall)
    }

    @Test("A start cancelled after PLDBGBREAK attaches and aborts, since the target ignores a cancel in accept()")
    func cancelAfterNoticeAttachesAndAborts() {
        #expect(PostgreSQLRoutineDebugProtocol.startCancellation(portDelivered: true, callEnded: false) == .attachAndAbort)
    }

    @Test("A start whose call already ended has nothing left to end")
    func cancelAfterTheCallEndedDoesNothing() {
        #expect(PostgreSQLRoutineDebugProtocol.startCancellation(portDelivered: false, callEnded: true) == .nothing)
    }

    @Test("Once the wait ends, a cancelled start aborts a target that announced its port and attaches otherwise")
    func startStepAfterTheWait() {
        #expect(PostgreSQLRoutineDebugProtocol.startStep(port: 7, isCancelled: true) == .attachAndAbort(port: 7))
        #expect(PostgreSQLRoutineDebugProtocol.startStep(port: 7, isCancelled: false) == .attach(port: 7))
        #expect(PostgreSQLRoutineDebugProtocol.startStep(port: nil, isCancelled: true) == .cancelled)
        #expect(PostgreSQLRoutineDebugProtocol.startStep(port: nil, isCancelled: false) == .endedBeforeEntry)
    }

    // MARK: - Errors

    @Test("A missing pldbg function maps to the extension being missing")
    func undefinedFunctionMapsToExtensionMissing() {
        let error = LibPQPluginError(
            message: "ERROR:  function public.pldbg_oid_debug(oid) does not exist",
            sqlState: "42883",
            detail: nil
        )
        let mapped = PostgreSQLRoutineDebugProtocol.startFailure(error, database: "noext", routineName: "f()")
        #expect(mapped as? PostgreSQLRoutineDebugError == .extensionMissing(database: "noext"))
    }

    @Test("pldebugger's owner check maps to the owner message")
    func ownerCheckMapsToNotOwner() {
        let error = LibPQPluginError(
            message: "ERROR:  must be owner or superuser to create a breakpoint",
            sqlState: "42501",
            detail: nil
        )
        let mapped = PostgreSQLRoutineDebugProtocol.startFailure(error, database: "postgres", routineName: "f()")
        #expect(mapped as? PostgreSQLRoutineDebugError == .notOwner(routine: "f()"))
    }

    @Test("Running out of shared memory names the preload fix")
    func sharedMemoryMapsToPreload() {
        let ownCheck = LibPQPluginError(message: "ERROR:  out of shared memory", sqlState: "XX000", detail: nil)
        let core = LibPQPluginError(
            message: "ERROR:  not enough shared memory for data structure \"Debugger Connection slots\" (64 bytes requested)",
            sqlState: "53200",
            detail: nil
        )
        for error in [ownCheck, core] {
            let mapped = PostgreSQLRoutineDebugProtocol.startFailure(error, database: "postgres", routineName: "f()")
            #expect(mapped as? PostgreSQLRoutineDebugError == .sharedMemoryUnavailable)
        }
    }

    @Test("Any other start error passes through unchanged")
    func otherStartErrorsPassThrough() {
        let error = LibPQPluginError(
            message: "ERROR:  invalid input syntax for type integer: \"abc\"",
            sqlState: "22P02",
            detail: nil
        )
        let mapped = PostgreSQLRoutineDebugProtocol.startFailure(error, database: "postgres", routineName: "f()")
        #expect((mapped as? LibPQPluginError)?.sqlState == "22P02")
    }

    @Test("The proxy's 08006 means the target finished, not that the proxy failed")
    func proxyTerminationIsFinished() {
        let terminated = LibPQPluginError(
            message: "ERROR:  debugger connection terminated",
            sqlState: "08006",
            detail: nil
        )
        let lost = LibPQConnectionLostError(
            loss: .afterSending,
            underlying: LibPQPluginError(message: "server closed the connection unexpectedly", sqlState: nil, detail: nil)
        )
        #expect(PostgreSQLRoutineDebugProtocol.proxyFailure(terminated) == .targetEnded)
        #expect(PostgreSQLRoutineDebugProtocol.proxyFailure(lost) == .broken)
        #expect(PostgreSQLRoutineDebugProtocol.proxyFailure(CancellationError()) == .broken)
    }

    @Test("A signal that interrupts the waiting proxy is told apart from the target leaving")
    func interruptedProxyIsNotTheEnd() {
        let interrupted = LibPQPluginError(
            message: "ERROR:  select() failed waiting for target",
            sqlState: "08006",
            detail: nil
        )
        #expect(PostgreSQLRoutineDebugProtocol.proxyFailure(interrupted) == .interrupted)
    }

    @Test("A target ended after an interruption says so, with the server's CONTEXT as the detail")
    func interruptedEndSaysSo() {
        let error = LibPQPluginError(
            message: """
                ERROR:  canceling statement due to user request
                CONTEXT:  PL/pgSQL function two_stops() line 6 at assignment
                """,
            sqlState: "57014",
            detail: nil
        )
        guard case .failed(let message, let detail) = PostgreSQLRoutineDebugProtocol.end(
            of: .failure(error),
            stopRequested: false,
            interrupted: true
        ) else {
            Issue.record("expected a failed stop")
            return
        }
        #expect(message == PostgreSQLRoutineDebugProtocol.interruptedMessage)
        #expect(detail == "CONTEXT:  PL/pgSQL function two_stops() line 6 at assignment")
    }

    @Test("A target that could not be ended is named, with the SQL that ends it")
    func abandonedTargetIsNamed() {
        let both = PostgreSQLRoutineDebugProtocol.abandonedDetail(process: 4_242, port: 11)
        #expect(both.contains("4242"))
        #expect(both.contains("pldbg_attach_to_port(11)"))
        #expect(both.contains("pldbg_abort_target"))
        #expect(PostgreSQLRoutineDebugProtocol.abandonedDetail(process: 4_242, port: nil).contains("4242"))
        #expect(!PostgreSQLRoutineDebugProtocol.abandonedDetail(process: nil, port: 11).isEmpty)
        guard case .failed(let message, let detail) = PostgreSQLRoutineDebugProtocol.abandonedStop(process: 4_242, port: 11) else {
            Issue.record("expected a failed stop")
            return
        }
        #expect(message == PostgreSQLRoutineDebugProtocol.abandonedMessage)
        #expect(detail == both)
    }

    @Test("Giving up on a target releases its waiters and marks it abandoned, unless its call already ended")
    func rendezvousAbandon() async {
        let waiting = PostgreSQLDebugRendezvous()
        async let port = waiting.port()
        waiting.abandon()
        #expect(await port == nil)
        #expect(waiting.isAbandoned)
        #expect(waiting.hasSettled)

        let ended = PostgreSQLDebugRendezvous()
        ended.settle()
        ended.abandon()
        #expect(!ended.isAbandoned)
    }

    @Test("The target's 57014 after Stop reads as stopped, keeping where it stopped")
    func cancelAfterStopIsStopped() {
        let error = LibPQPluginError(
            message: """
                ERROR:  canceling statement due to user request
                CONTEXT:  PL/pgSQL function order_total(integer,numeric) line 13 at assignment
                """,
            sqlState: "57014",
            detail: nil
        )
        guard case .failed(let message, let detail) = PostgreSQLRoutineDebugProtocol.end(
            of: .failure(error),
            stopRequested: true
        ) else {
            Issue.record("expected a failed stop")
            return
        }
        #expect(message == PostgreSQLRoutineDebugProtocol.stoppedMessage)
        #expect(detail == "CONTEXT:  PL/pgSQL function order_total(integer,numeric) line 13 at assignment")
    }

    @Test("The plugin's own cancel of the target reads as stopped")
    func cancellationIsStopped() {
        guard case .failed(let message, _) = PostgreSQLRoutineDebugProtocol.end(
            of: .failure(CancellationError()),
            stopRequested: true
        ) else {
            Issue.record("expected a failed stop")
            return
        }
        #expect(message == PostgreSQLRoutineDebugProtocol.stoppedMessage)
    }

    @Test("A routine error carries the server's message, with its CONTEXT lines as the detail")
    func routineErrorKeepsContext() {
        let error = LibPQPluginError(
            message: """
                ERROR:  canceling statement due to user request
                CONTEXT:  SQL statement "SELECT pg_sleep(4)"
                PL/pgSQL function slow_fn() line 4 at PERFORM
                """,
            sqlState: "57014",
            detail: nil
        )
        guard case .failed(let message, let detail) = PostgreSQLRoutineDebugProtocol.end(
            of: .failure(error),
            stopRequested: false
        ) else {
            Issue.record("expected a failed stop")
            return
        }
        #expect(message == "canceling statement due to user request")
        #expect(detail == "CONTEXT:  SQL statement \"SELECT pg_sleep(4)\"\nPL/pgSQL function slow_fn() line 4 at PERFORM")
    }

    @Test("A finished routine carries its result, or none when it returned no columns")
    func finishedCarriesResult() {
        if case .finished(let result) = PostgreSQLRoutineDebugProtocol.end(
            of: .success(Self.result(columns: ["order_total"])),
            stopRequested: false
        ) {
            #expect(result?.columns == ["order_total"])
        } else {
            Issue.record("expected a finished stop")
        }
        if case .finished(let result) = PostgreSQLRoutineDebugProtocol.end(
            of: .success(Self.result(columns: [])),
            stopRequested: false
        ) {
            #expect(result == nil)
        } else {
            Issue.record("expected a finished stop")
        }
    }
}
