//
//  PostgreSQLRoutineDebugProtocol.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

struct PostgreSQLDebugCall: Equatable, Sendable {
    let sql: String
    let parameters: [PluginCellValue]
}

enum PostgreSQLDebugProxyFailure: Equatable {
    case targetEnded
    // A signal reached the proxy while it waited: the target is still attached to it and its reply is unread.
    case interrupted
    case broken
}

// How to end a target whose start was cancelled.
enum PostgreSQLDebugStartCancellation: Equatable {
    // The call has not reached the routine: a cancel on the target ends it.
    case cancelCall
    // The target waits in accept() and ignores a cancel: only an attach and pldbg_abort_target end it.
    case attachAndAbort
    case nothing
}

// What start does once the call reached the routine or ended.
enum PostgreSQLDebugStartStep: Equatable {
    case attach(port: Int)
    case attachAndAbort(port: Int)
    case cancelled
    case endedBeforeEntry
}

struct PostgreSQLDebugRoutine: Equatable, Sendable {
    let identity: String
    let database: String
    let extensionSchema: String?
    let extensionAvailable: Bool
    let exists: Bool
    let mayDebug: Bool
    let kind: String?
    let volatility: String?
    let language: String?
    let schema: String
    let name: String
    let identityArguments: String
    let returnsRecordType: Bool
    let returnsTrigger: Bool
    let parameters: [PluginDebugParameter]
    let takesPseudoType: Bool
    let configuration: [String]
    // Each argument's type as its quoted, schema-qualified pg_type name ("pg_catalog"."bit"), parallel to
    // `parameters`. It names exactly the declared type and no length: format_type's character and bit mean
    // character(1) and bit(1) and cut the value, and bpchar or varbit pick an f(bit varying) overload over the
    // f(bit) being debugged (both measured).
    let argumentCastTypes: [String]
    // Each argument's default expression from pg_get_function_arg_default, nil where it has none.
    let defaultExpressions: [String?]

    // The columns of `PostgreSQLRoutineDebugProtocol.routineQuery`, in order.
    init(row: [String?], identity: String) {
        func text(_ index: Int) -> String? { row.indices.contains(index) ? row[index] : nil }
        func flag(_ index: Int) -> Bool { PostgreSQLCatalogBoolean.isTrue(text(index)) }
        self.identity = identity
        database = text(0) ?? ""
        extensionSchema = text(1)
        extensionAvailable = flag(2)
        exists = flag(3)
        mayDebug = flag(4)
        kind = text(5)
        volatility = text(6)
        language = text(7)
        schema = text(8) ?? ""
        name = text(9) ?? ""
        identityArguments = text(10) ?? ""
        returnsRecordType = flag(11)
        returnsTrigger = flag(12)
        parameters = PostgreSQLRoutineDebugProtocol.parameters(
            types: PostgreSQLTextArray.values(text(13)),
            names: PostgreSQLTextArray.elements(text(14)),
            modes: PostgreSQLTextArray.values(text(15)),
            defaultCount: text(16).flatMap { Int($0) } ?? 0
        )
        takesPseudoType = flag(17)
        configuration = PostgreSQLTextArray.values(text(18))
        argumentCastTypes = PostgreSQLTextArray.values(text(19))
        defaultExpressions = PostgreSQLTextArray.elements(text(20))
    }

    var isProcedure: Bool { kind == "p" }

    var displayName: String { "\(name)(\(identityArguments))" }

    var returnsBareRecord: Bool {
        returnsRecordType && !parameters.contains { $0.mode == .output || $0.mode == .inputOutput }
    }

    var entryPoint: PluginDebugEntryPoint {
        PluginDebugEntryPoint(identity: identity, displayName: displayName, parameters: parameters)
    }

    var runNote: String {
        isProcedure
            ? String(
                localized: """
                    Changes the procedure makes are committed when it commits or finishes. Stop rolls back what it \
                    hasn't committed.
                    """
            )
            : String(localized: "Changes the routine makes are committed when it finishes. Stop rolls them back.")
    }

    // Never gates on shared_preload_libraries: a non-superuser cannot read it, and direct debugging works without it.
    func debuggerSchema() throws -> String {
        guard language == "plpgsql", kind == "f" || kind == "p", !returnsTrigger else {
            throw PostgreSQLRoutineDebugError.notDebuggable
        }
        guard !takesPseudoType else { throw PostgreSQLRoutineDebugError.pseudoTypeParameter }
        if let blocking = PostgreSQLRoutineDebugProtocol.blockingSetting(in: configuration) { throw blocking }
        guard let extensionSchema, !extensionSchema.isEmpty else {
            throw extensionAvailable
                ? PostgreSQLRoutineDebugError.extensionMissing(database: database)
                : PostgreSQLRoutineDebugError.serverPackageMissing
        }
        guard mayDebug else { throw PostgreSQLRoutineDebugError.notOwner(routine: displayName) }
        return extensionSchema
    }
}

enum PostgreSQLRoutineDebugProtocol {
    static let supportedCommands: Set<PluginDebugCommand> = [.continueExecution, .stepOver, .stepInto]

    private static let breakNoticePrefix = "PLDBGBREAK:"
    private static let targetEndedState = "08006"
    private static let queryCanceledState = "57014"
    private static let triggerReturnTypes: Set<String> = ["trigger", "event_trigger"]
    // A bound text argument stays unknown for a polymorphic parameter, and text cannot become a bare record, so a
    // routine taking one of these cannot be called by the debugger.
    private static let pseudoArgumentTypes: Set<String> = [
        "\"any\"", "anyelement", "anyarray", "anynonarray", "anyenum", "anyrange", "anymultirange",
        "anycompatible", "anycompatiblearray", "anycompatiblenonarray", "anycompatiblerange",
        "anycompatiblemultirange", "record", "record[]"
    ]

    static var stoppedMessage: String {
        String(localized: "The routine was stopped, and its uncommitted changes were rolled back.")
    }

    // A cancel reaching the proxy does this, and so does a server transaction_timeout on PostgreSQL 17 once a wait
    // outlasts it, even with the session's own set to 0 (measured on 17.11).
    static var interruptedMessage: String {
        String(
            localized: """
                The debugger's session was interrupted while it waited, so the routine was stopped and its uncommitted \
                changes were rolled back. A cancel or the server's transaction_timeout can cause this.
                """
        )
    }

    static func abandonedStop(process: Int?, port: Int?) -> PluginDebugStop {
        .failed(message: abandonedMessage, detail: abandonedDetail(process: process, port: port))
    }

    static var abandonedMessage: String {
        String(localized: "The routine couldn't be stopped on the server.")
    }

    // Names the backend so someone with access can end it: a target waiting for a debugger ignores cancel and
    // terminate, and only an attach followed by pldbg_abort_target ends it.
    static func abandonedDetail(process: Int?, port: Int?) -> String {
        switch (process, port) {
        case let (process?, port?):
            return String(
                format: String(
                    localized: """
                        Server process %d may still be waiting for a debugger and holding its locks. To end it, run \
                        SELECT pldbg_attach_to_port(%d) and pass the number it returns to pldbg_abort_target.
                        """
                ),
                process,
                port
            )
        case let (process?, nil):
            return String(format: String(localized: "Server process %d may still be running and holding its locks."), process)
        case (nil, _):
            return String(localized: "Its server session may still be running and holding its locks.")
        }
    }

    // MARK: - Session setup

    static func sessionSettings(serverVersion: Int32, isTarget: Bool) -> [String] {
        // Each would end a target paused at a breakpoint, or the proxy while it waits for one. A paused target is
        // active and the proxy idle outside a transaction, so idle_in_transaction_session_timeout never applies.
        var statements = ["SET statement_timeout = 0"]
        if serverVersion >= 140_000 {
            statements.append("SET idle_session_timeout = 0")
        }
        if serverVersion >= 170_000 {
            statements.append("SET transaction_timeout = 0")
        }
        // The target announces the port it waits on as a NOTICE, which a stricter level never sends.
        if isTarget {
            statements.append("SET client_min_messages = notice")
        }
        return statements
    }

    // Startup commands can leave a transaction open; the routine's changes must neither join it nor be committed
    // by it, so it is rolled back before the call.
    static func endsStartupTransaction(_ state: PluginSessionTransactionState) -> Bool {
        state != .idle
    }

    // Every identity, the entry point's and each unit's, is the routine's oid.
    static func oid(inIdentity identity: String) -> UInt32? {
        UInt32(identity)
    }

    // MARK: - Catalog

    static func routineQuery(oid: UInt32, capabilities: PostgreSQLCapabilities) -> String {
        let kindColumn = capabilities.hasProcedureKind
            ? "p.prokind"
            : "CASE WHEN p.proisagg THEN 'a' WHEN p.proiswindow THEN 'w' ELSE 'f' END"
        let argumentTypes = "COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[])"
        // pg_get_function_arg_default (9.4) counts arguments from 1; proargtypes as an array starts at 0.
        let defaultsColumn = capabilities.serverVersion >= 90_400
            ? """
                ARRAY(
                    SELECT pg_catalog.pg_get_function_arg_default(
                        p.oid,
                        (s.i - pg_catalog.array_lower(\(argumentTypes), 1) + 1)::pg_catalog.int4
                    )
                    FROM pg_catalog.generate_subscripts(\(argumentTypes), 1) AS s(i)
                    ORDER BY s.i
                )
                """
            : "NULL::pg_catalog.text[]"
        return """
            SELECT
                pg_catalog.current_database(),
                (SELECT en.nspname FROM pg_catalog.pg_extension e
                    JOIN pg_catalog.pg_namespace en ON en.oid = e.extnamespace
                    WHERE e.extname = 'pldbgapi'),
                EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions a WHERE a.name = 'pldbgapi'),
                p.oid IS NOT NULL,
                COALESCE(p.proowner = r.oid OR r.rolsuper, false),
                \(kindColumn),
                p.provolatile,
                l.lanname,
                n.nspname,
                p.proname,
                pg_catalog.pg_get_function_identity_arguments(p.oid),
                p.prorettype = 'pg_catalog.record'::pg_catalog.regtype,
                p.prorettype IN ('pg_catalog.trigger'::pg_catalog.regtype, 'pg_catalog.event_trigger'::pg_catalog.regtype),
                ARRAY(
                    SELECT pg_catalog.format_type((\(argumentTypes))[s.i], NULL)
                    FROM pg_catalog.generate_subscripts(\(argumentTypes), 1) AS s(i)
                    ORDER BY s.i
                ),
                p.proargnames,
                p.proargmodes::pg_catalog.text[],
                p.pronargdefaults,
                \(pseudoTypeArgumentTest),
                p.proconfig,
                ARRAY(
                    SELECT '"' || pg_catalog.replace(tn.nspname, '"', '""') || '"."'
                        || pg_catalog.replace(ty.typname, '"', '""') || '"'
                    FROM pg_catalog.generate_subscripts(\(argumentTypes), 1) AS s(i)
                    JOIN pg_catalog.pg_type ty ON ty.oid = (\(argumentTypes))[s.i]
                    JOIN pg_catalog.pg_namespace tn ON tn.oid = ty.typnamespace
                    ORDER BY s.i
                ),
                \(defaultsColumn)
            FROM (SELECT 1) AS one
            LEFT JOIN pg_catalog.pg_proc p ON p.oid = \(oidLiteral(oid))
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            LEFT JOIN pg_catalog.pg_roles r ON r.rolname = CURRENT_USER
            """
    }

    static func targetListQuery(schema: String, hasProcedureKind: Bool) -> String {
        let kindColumn = hasProcedureKind ? "p.prokind" : "'f'"
        let kindFilter = hasProcedureKind ? "p.prokind IN ('f', 'p')" : "NOT p.proisagg AND NOT p.proiswindow"
        return """
            SELECT
                p.oid::pg_catalog.text,
                p.proname,
                n.nspname,
                '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')',
                \(kindColumn)
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
                AND l.lanname = 'plpgsql'
                AND \(kindFilter)
                AND p.prorettype NOT IN ('pg_catalog.trigger'::pg_catalog.regtype, 'pg_catalog.event_trigger'::pg_catalog.regtype)
                AND NOT \(pseudoTypeArgumentTest)
                AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_depend d
                    WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objid = p.oid AND d.deptype = 'e'
                )
            ORDER BY p.proname, 4
            """
    }

    // proargtypes holds the arguments a call passes; a pseudo-type there (anyelement, record) cannot be bound.
    private static let pseudoTypeArgumentTest = """
        EXISTS (
                    SELECT 1 FROM pg_catalog.unnest(p.proargtypes::pg_catalog.oid[]) AS a(t)
                    JOIN pg_catalog.pg_type ty ON ty.oid = a.t
                    WHERE ty.typtype = 'p'
                )
        """

    static func routineSourceStatement(oid: UInt32) -> String {
        "SELECT p.prosrc FROM pg_catalog.pg_proc p WHERE p.oid = \(oidLiteral(oid))"
    }

    // MARK: - pldbgapi calls

    static func oidDebugStatement(extensionSchema: String, oid: UInt32) -> String {
        "SELECT \(function("pldbg_oid_debug", in: extensionSchema))(\(oidLiteral(oid)))"
    }

    // The argument is the target's backend number from its PLDBGBREAK notice, not a TCP port.
    static func attachStatement(extensionSchema: String, port: Int) -> String {
        "SELECT \(function("pldbg_attach_to_port", in: extensionSchema))(\(port))"
    }

    static func waitStatement(extensionSchema: String, session: Int) -> String {
        breakpointRead("pldbg_wait_for_breakpoint", extensionSchema, "\(session)")
    }

    static func stepStatement(_ command: PluginDebugCommand, extensionSchema: String, session: Int) -> String? {
        let name: String
        switch command {
        case .continueExecution:
            name = "pldbg_continue"
        case .stepOver:
            name = "pldbg_step_over"
        case .stepInto:
            name = "pldbg_step_into"
        case .stepOut:
            return nil
        @unknown default:
            return nil
        }
        return breakpointRead(name, extensionSchema, "\(session)")
    }

    static func selectFrameStatement(extensionSchema: String, session: Int, level: Int) -> String {
        breakpointRead("pldbg_select_frame", extensionSchema, "\(session), \(level)")
    }

    static func sourceStatement(extensionSchema: String, session: Int, oid: UInt32) -> String {
        "SELECT \(function("pldbg_get_source", in: extensionSchema))(\(session), \(oidLiteral(oid)))"
    }

    static func stackStatement(extensionSchema: String, session: Int) -> String {
        "SELECT level, targetname, func, linenumber, args FROM \(function("pldbg_get_stack", in: extensionSchema))(\(session))"
    }

    static func variablesStatement(extensionSchema: String, session: Int) -> String {
        """
        SELECT name, varclass, linenumber, isunique, isconst, isnotnull, pg_catalog.format_type(dtype, NULL), value \
        FROM \(function("pldbg_get_variables", in: extensionSchema))(\(session))
        """
    }

    static func setBreakpointStatement(extensionSchema: String, session: Int, oid: UInt32, line: Int) -> String {
        "SELECT \(function("pldbg_set_breakpoint", in: extensionSchema))(\(session), \(oidLiteral(oid)), \(line))"
    }

    static func dropBreakpointStatement(extensionSchema: String, session: Int, oid: UInt32, line: Int) -> String {
        "SELECT \(function("pldbg_drop_breakpoint", in: extensionSchema))(\(session), \(oidLiteral(oid)), \(line))"
    }

    static func abortStatement(extensionSchema: String, session: Int) -> String {
        "SELECT * FROM \(function("pldbg_abort_target", in: extensionSchema))(\(session))"
    }

    private static func breakpointRead(_ name: String, _ extensionSchema: String, _ arguments: String) -> String {
        "SELECT func, linenumber, targetname FROM \(function(name, in: extensionSchema))(\(arguments))"
    }

    // pldbgapi is relocatable, so every call names the schema it was created in.
    private static func function(_ name: String, in extensionSchema: String) -> String {
        "\(PostgreSQLObjectQueries.quoteIdentifier(extensionSchema)).\(name)"
    }

    static func oidLiteral(_ oid: UInt32) -> String {
        "\(PostgreSQLObjectQueries.quoteLiteral(String(oid)))::pg_catalog.oid"
    }

    // MARK: - Replies

    static func debuggerPort(inNotice message: String) -> Int? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(breakNoticePrefix) else { return nil }
        return Int(trimmed.dropFirst(breakNoticePrefix.count))
    }

    // The stop pldebugger reports is one past the statement's line (plpgsql_debugger.c sends lineno + 1);
    // stack frames and breakpoints use the line itself.
    static func location(fromBreakpointRow row: [String?]) -> PluginDebugLocation? {
        guard let unit = cell(row, 0), !unit.isEmpty,
              let reported = cell(row, 1).flatMap({ Int($0) })
        else { return nil }
        return PluginDebugLocation(
            unit: PluginDebugUnit(identity: unit, displayName: cell(row, 2) ?? unit),
            line: max(reported - 1, 1)
        )
    }

    static func frame(fromStackRow row: [String?]) -> PluginDebugFrame? {
        guard let level = cell(row, 0).flatMap({ Int($0) }) else { return nil }
        var location: PluginDebugLocation?
        if let unit = cell(row, 2), let line = cell(row, 3).flatMap({ Int($0) }) {
            location = PluginDebugLocation(
                unit: PluginDebugUnit(identity: unit, displayName: cell(row, 1) ?? unit),
                line: line
            )
        }
        return PluginDebugFrame(level: level, location: location, arguments: cell(row, 4))
    }

    static func variable(fromRow row: [String?]) -> PluginDebugVariable? {
        guard let name = cell(row, 0) else { return nil }
        let value = cell(row, 7)
        return PluginDebugVariable(
            name: name,
            kind: variableKind(cell(row, 1)),
            typeName: cell(row, 6),
            // pldebugger sends SQL NULL as the text NULL, so it cannot be told from the string 'NULL'.
            value: value == "NULL" ? nil : value,
            isConstant: PostgreSQLCatalogBoolean.isTrue(cell(row, 4))
        )
    }

    static func variableKind(_ code: String?) -> PluginDebugVariableKind {
        switch code {
        case "A": return .argument
        case "P": return .package
        default: return .local
        }
    }

    private static func cell(_ row: [String?], _ index: Int) -> String? {
        row.indices.contains(index) ? row[index] : nil
    }

    // MARK: - Targets

    static func target(for routine: PluginRoutineInfo) -> PluginDebugTarget? {
        guard routine.language?.lowercased() == "plpgsql",
              let identity = routine.identity, UInt32(identity) != nil,
              !triggerReturnTypes.contains(routine.returnType?.lowercased() ?? ""),
              !signatureTakesPseudoType(routine.argumentSignature)
        else { return nil }
        return PluginDebugTarget(
            identity: identity,
            name: routine.name + (routine.argumentSignature ?? ""),
            schema: routine.schema,
            kindDisplayName: kindDisplayName(isProcedure: routine.kind == .procedure)
        )
    }

    // The signature is pg_get_function_identity_arguments in parentheses: "(IN a integer, b anyelement)". A type is
    // the last word of its argument, so a parameter named like a type does not count.
    static func signatureTakesPseudoType(_ signature: String?) -> Bool {
        guard let signature else { return false }
        var body = Substring(signature.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("("), body.hasSuffix(")") {
            body = body.dropFirst().dropLast()
        }
        return quoteAwareSplit(body, separator: ",").contains { argument in
            guard let type = quoteAwareSplit(argument, separator: " ").last(where: { !$0.isEmpty }) else { return false }
            return pseudoArgumentTypes.contains(String(type))
        }
    }

    private static func quoteAwareSplit(_ text: Substring, separator: Character) -> [Substring] {
        var parts: [Substring] = []
        var start = text.startIndex
        var quoted = false
        for index in text.indices {
            if text[index] == "\"" {
                quoted.toggle()
            } else if text[index] == separator, !quoted {
                parts.append(text[start..<index])
                start = text.index(after: index)
            }
        }
        parts.append(text[start...])
        return parts.map { $0.trimmingCharacters(in: .whitespaces)[...] }
    }

    static func target(fromListRow row: [String?]) -> PluginDebugTarget? {
        guard let identity = cell(row, 0), UInt32(identity) != nil, let name = cell(row, 1) else { return nil }
        return PluginDebugTarget(
            identity: identity,
            name: name + (cell(row, 3) ?? ""),
            schema: cell(row, 2),
            kindDisplayName: kindDisplayName(isProcedure: cell(row, 4) == "p")
        )
    }

    private static func kindDisplayName(isProcedure: Bool) -> String {
        isProcedure ? String(localized: "Procedure") : String(localized: "Function")
    }

    // MARK: - Parameters and the call

    static func parameters(types: [String], names: [String?], modes: [String], defaultCount: Int) -> [PluginDebugParameter] {
        let resolvedModes = types.indices.map { parameterMode(modes.indices.contains($0) ? modes[$0] : "i") }
        let inputs = types.indices.filter { resolvedModes[$0] != .output }
        let defaulted = Set(inputs.suffix(max(defaultCount, 0)))
        return types.indices.map { index in
            let declared = names.indices.contains(index) ? names[index] ?? "" : ""
            return PluginDebugParameter(
                name: declared.isEmpty ? "$\(index + 1)" : declared,
                typeName: types[index],
                mode: resolvedModes[index],
                hasDefault: defaulted.contains(index)
            )
        }
    }

    static func parameterMode(_ code: String) -> PluginDebugParameterMode {
        switch code {
        case "o", "t": return .output
        case "b": return .inputOutput
        case "v": return .variadic
        default: return .input
        }
    }

    static func call(for routine: PostgreSQLDebugRoutine, arguments: [PluginDebugArgument]) throws -> PostgreSQLDebugCall {
        var values: [String: PluginDebugArgumentValue] = [:]
        for argument in arguments {
            values[argument.parameterName] = argument.value
        }
        var expressions: [String] = []
        var bound: [PluginCellValue] = []
        for (index, parameter) in routine.parameters.enumerated() {
            let castType = routine.argumentCastTypes.indices.contains(index)
                ? routine.argumentCastTypes[index]
                : parameter.typeName
            var expression: String
            if parameter.mode == .output {
                // CALL takes a placeholder for each OUT parameter; a function call takes none.
                guard routine.isProcedure else { continue }
                expression = "NULL::\(castType)"
            } else {
                switch values[parameter.name] ?? (parameter.hasDefault ? .defaultValue : .null) {
                case .text(let text):
                    bound.append(.text(text))
                    expression = "$\(bound.count)::\(castType)"
                case .defaultValue:
                    expression = "(\(try defaultExpression(of: parameter, at: index, in: routine)))::\(castType)"
                case .null:
                    bound.append(.null)
                    expression = "$\(bound.count)::\(castType)"
                @unknown default:
                    bound.append(.null)
                    expression = "$\(bound.count)::\(castType)"
                }
            }
            if parameter.mode == .variadic {
                expression = "VARIADIC " + expression
            }
            expressions.append(expression)
        }

        let routineName = PostgreSQLObjectQueries.qualifiedName(schema: routine.schema, name: routine.name)
        let argumentList = expressions.joined(separator: ", ")
        let sql: String
        if routine.isProcedure {
            sql = "CALL \(routineName)(\(argumentList))"
        } else if routine.returnsBareRecord {
            // SELECT * FROM a function returning a bare record needs a column definition list.
            sql = "SELECT \(routineName)(\(argumentList))"
        } else {
            sql = "SELECT * FROM \(routineName)(\(argumentList))"
        }
        return PostgreSQLDebugCall(sql: sql, parameters: bound)
    }

    // Never left out: overloads that differ only in defaulted parameters make f() ambiguous although the selected
    // oid is known. The routine's own default expression, cast to the exact type, names that overload and is
    // evaluated in the call just as an omitted argument's would be.
    private static func defaultExpression(
        of parameter: PluginDebugParameter,
        at index: Int,
        in routine: PostgreSQLDebugRoutine
    ) throws -> String {
        guard parameter.hasDefault else {
            throw PostgreSQLRoutineDebugError.noDefault(parameter: parameter.name)
        }
        guard routine.defaultExpressions.indices.contains(index), let expression = routine.defaultExpressions[index] else {
            throw PostgreSQLRoutineDebugError.defaultNotReadable(parameter: parameter.name)
        }
        return expression
    }

    // MARK: - Starting

    static func startCancellation(portDelivered: Bool, callEnded: Bool) -> PostgreSQLDebugStartCancellation {
        if portDelivered { return .attachAndAbort }
        return callEnded ? .nothing : .cancelCall
    }

    static func startStep(port: Int?, isCancelled: Bool) -> PostgreSQLDebugStartStep {
        guard let port else { return isCancelled ? .cancelled : .endedBeforeEntry }
        return isCancelled ? .attachAndAbort(port: port) : .attach(port: port)
    }

    // MARK: - Outcomes

    static func startFailure(_ error: Error, database: String, routineName: String) -> Error {
        guard let failure = error as? any PluginDriverError else { return error }
        let state = failure.pluginSqlState
        let message = failure.pluginErrorMessage
        if isSharedMemoryFailure(sqlState: state, message: message) {
            return PostgreSQLRoutineDebugError.sharedMemoryUnavailable
        }
        if state == "42883", message.contains("pldbg_") {
            return PostgreSQLRoutineDebugError.extensionMissing(database: database)
        }
        if state == "42501", message.contains("must be owner or superuser") {
            return PostgreSQLRoutineDebugError.notOwner(routine: routineName)
        }
        return error
    }

    // Without the preload, pldebugger takes its slots from spare shared memory (dbgcomm.c) and can run out.
    private static func isSharedMemoryFailure(sqlState: String?, message: String) -> Bool {
        message.contains("out of shared memory")
            || message.contains("Debugger Connection slots")
            || (sqlState == "53200" && message.contains("shared memory"))
    }

    // pldbgapi raises 08006 in two cases: "debugger connection terminated" when the target left the debugger,
    // finished or not, and "select() failed waiting for target" when a signal reached the waiting proxy.
    static func proxyFailure(_ error: Error) -> PostgreSQLDebugProxyFailure {
        guard let failure = error as? LibPQPluginError, failure.sqlState == targetEndedState else { return .broken }
        return failure.message.contains("select() failed") ? .interrupted : .targetEnded
    }

    static func end(
        of outcome: Result<PluginQueryResult, Error>,
        stopRequested: Bool,
        interrupted: Bool = false
    ) -> PluginDebugStop {
        let ownMessage = interrupted ? interruptedMessage : stoppedMessage
        switch outcome {
        case .success(let result):
            return .finished(result.columns.isEmpty ? nil : result)
        case .failure(let error):
            if error is CancellationError {
                return .failed(message: ownMessage, detail: nil)
            }
            let failure = error as? any PluginDriverError
            let parts = serverMessage(failure?.pluginErrorMessage ?? error.localizedDescription)
            if stopRequested || interrupted, failure?.pluginSqlState == queryCanceledState {
                return .failed(message: ownMessage, detail: parts.detail)
            }
            return .failed(message: parts.message, detail: parts.detail)
        }
    }

    // A routine's own SET overrides the session's on entry (measured): a stricter client_min_messages hides the
    // PLDBGBREAK notice, so the start never sees the target, and a transaction_timeout ends a target that waits
    // at a breakpoint.
    static func blockingSetting(in configuration: [String]) -> PostgreSQLRoutineDebugError? {
        for entry in configuration {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let name = entry[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = entry[entry.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "client_min_messages" where noticeHidingLevels.contains(value.lowercased()):
                return .hidesDebuggerNotice(value: value)
            case "transaction_timeout" where !isZeroDuration(value):
                return .limitsTransactionTime(value: value)
            default:
                continue
            }
        }
        return nil
    }

    private static let noticeHidingLevels: Set<String> = ["warning", "error", "fatal", "panic"]

    private static func isZeroDuration(_ value: String) -> Bool {
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.allSatisfy({ $0 == "0" }) else { return false }
        return ["", "us", "ms", "s", "min", "h", "d"].contains(value.dropFirst(digits.count).lowercased())
    }

    // libpq formats an error as "SEVERITY:  message" followed by DETAIL, HINT and CONTEXT lines.
    static func serverMessage(_ text: String) -> (message: String, detail: String?) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return (text, nil) }
        let detail = lines.dropFirst().joined(separator: "\n")
        return (withoutSeverity(first), detail.isEmpty ? nil : detail)
    }

    private static func withoutSeverity(_ line: String) -> String {
        guard let separator = line.range(of: ":  ") else { return line }
        let label = line[..<separator.lowerBound]
        guard !label.isEmpty, label.allSatisfy(\.isLetter) else { return line }
        return String(line[separator.upperBound...])
    }
}
