import Foundation

public enum OracleDebugMechanism: String, Sendable, Hashable, CaseIterable {
    case jdwp
    case dbmsDebug
}

public enum OracleDebugCommand: Sendable, Hashable {
    case continueExecution
    case stepOver
    case stepInto
    case stepOut
}

public struct OracleDebugLocation: Sendable, Hashable {
    public let unit: OracleDebugUnit
    public let line: Int

    public init(unit: OracleDebugUnit, line: Int) {
        self.unit = unit
        self.line = line
    }
}

public struct OracleDebugOutcome: Sendable, Equatable {
    public struct Value: Sendable, Equatable {
        public let name: String
        public let typeName: String
        public let value: String?

        public init(name: String, typeName: String, value: String?) {
            self.name = name
            self.typeName = typeName
            self.value = value
        }
    }

    // The function's result first, then each OUT and IN OUT parameter whose value can be shown as text.
    public let values: [Value]

    public init(values: [Value]) {
        self.values = values
    }
}

public enum OracleDebugStop: Sendable, Equatable {
    case paused(OracleDebugLocation)
    case finished(OracleDebugOutcome)
    case failed(OracleDebugFailure)
}

public enum OracleDebugFailure: Sendable, Equatable {
    // The routine raised; the server's own message.
    case routineFailed(String)
    case stopped
    // Stop could not end a routine running between breakpoints under DBMS_DEBUG; it ends on its own.
    case stillRunning(OracleDebugSessionIdentity?)
    case connectionLost(String?)
}

public enum OracleDebugStopResult: Sendable, Equatable {
    // The routine's call ended, so its uncommitted work is rolled back and its locks are gone.
    case ended
    // Nothing confirmed the end inside the budget; the session may still run and hold locks.
    case unconfirmed(OracleDebugSessionIdentity?)
}

public struct OracleDebugSessionIdentity: Sendable, Hashable {
    public let sid: Int
    public let serial: Int?
    // On RAC a SID and SERIAL# name a session only within its instance, and the kill may go through another one.
    public let instance: Int?

    public init(sid: Int, serial: Int?, instance: Int? = nil) {
        self.sid = sid
        self.serial = serial
        self.instance = instance
    }
}

public struct OracleDebugFrame: Sendable, Hashable {
    public let level: Int
    public let location: OracleDebugLocation
    public let subprogram: String?

    public init(level: Int, location: OracleDebugLocation, subprogram: String?) {
        self.level = level
        self.location = location
        self.subprogram = subprogram
    }
}

public enum OracleDebugVariableKind: Sendable, Hashable {
    case argument
    case local
    case package
}

public struct OracleDebugVariable: Sendable, Hashable {
    public let name: String
    public let kind: OracleDebugVariableKind
    public let typeName: String?
    public let value: OracleDebugValue
    public let isConstant: Bool

    public init(name: String, kind: OracleDebugVariableKind, typeName: String?, value: OracleDebugValue, isConstant: Bool) {
        self.name = name
        self.kind = kind
        self.typeName = typeName
        self.value = value
        self.isConstant = isConstant
    }
}

// Things the person should read in the debugger's output: the engine says what happened, the plugin words it.
public enum OracleDebugNotice: Sendable, Equatable {
    case connectedOverJDWP(host: String, port: Int)
    case fellBack(OracleJDWPFailure, host: String, port: Int)
    case usingDBMSDebug(reason: OracleDebugProbeReason)
    case breakpointHasNoCode(unit: OracleDebugUnit, line: Int)
    case breakpointMoved(unit: OracleDebugUnit, from: Int, to: Int)
    case serverOutput(String)
}

public enum OracleDebugProbeReason: Sendable, Equatable {
    case chosen
    case noDebuggerHost
}

public enum OracleDebugError: Error, Sendable, Equatable {
    case privilegeMissing(String)
    case server(code: Int?, message: String)
    case jdwp(OracleJDWPFailure)
    case notPaused
    case ended
    case unsupportedArgument(name: String, typeName: String)
    case undeclarableArgument(name: String, typeName: String)
    // Leaving these defaulted parameters out would match another overload of the subprogram too.
    case ambiguousDefaults(subprogram: String, parameters: [String])
    case ambiguousCall(subprogram: String)
    // A JDWP command the database answered with an error code.
    case debuggerRefused(code: Int)
    // A DBMS_DEBUG answer that does not parse.
    case unreadableAnswer
    case unitNotFound
    case malformedReply
    // A JDWP command got no answer within the reply timeout; the connection, and with it the target, was closed.
    case debuggerStoppedAnswering
}

// Why the database did not connect back over JDWP. Each but `missingPrivilege` and `other` falls back to DBMS_DEBUG.
public enum OracleJDWPFailure: Sendable, Equatable {
    case accessControlList
    case unreachable(String)
    case packageUnavailable
    case timedOut
    case noFreePort
    case handshakeFailed
    // Explicit DBMS_DEBUG_JDWP with an empty Debugger Host.
    case noDebuggerHost
    // Connections came only from these addresses, none of them the database server's.
    case unexpectedPeer([String])
    case missingPrivilege
    case other(String)
}

public protocol OracleDebugEngine: AnyObject, Sendable {
    var mechanism: OracleDebugMechanism { get }
    var supportsStepOut: Bool { get }
    var notices: AsyncStream<OracleDebugNotice> { get }
    func firstStop() async throws -> OracleDebugStop
    func perform(_ command: OracleDebugCommand) async throws -> OracleDebugStop
    func stack() async throws -> [OracleDebugFrame]
    func variables(inFrame level: Int) async throws -> [OracleDebugVariable]
    // The line the breakpoint landed on, or nil when the unit has no code there.
    func setBreakpoint(in unit: OracleDebugUnit, line: Int) async throws -> Int?
    func removeBreakpoint(in unit: OracleDebugUnit, line: Int) async throws
    func source(of unit: OracleDebugUnit) async throws -> String
    // Returns within 3 seconds, whatever call it overlaps; that call then ends promptly.
    func stop() async -> OracleDebugStopResult
}
