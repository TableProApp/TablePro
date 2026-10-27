import Foundation

public protocol PluginRoutineDebugging: AnyObject, Sendable {
    // False on a driver that inherits the conformance but cannot debug (PGlite), so a menu can ask without I/O.
    var canDebugRoutines: Bool { get }
    // Synchronous so a context menu can ask without I/O; nil means this routine cannot be debugged.
    func debugTarget(for routine: PluginRoutineInfo) -> PluginDebugTarget?
    func debugTargets(schema: String?) async throws -> [PluginDebugTarget]
    func prepareDebug(_ target: PluginDebugTarget) async throws -> PluginDebugPlan
    // Every driver the plugin takes from `sessions` is closed by the host once the session ends.
    // Cancelling the task that awaits this ends the target as `stop()` would, then throws CancellationError.
    func startDebug(
        _ request: PluginDebugRequest,
        sessions: any PluginDebugSessionSource
    ) async throws -> any PluginDebugSession
}

public protocol PluginDebugSessionSource: Sendable {
    func openSession() async throws -> any PluginDatabaseDriver
}

// The host never overlaps two calls, except `stop()`, which may arrive while any other call is still running: that
// call then ends promptly (a waiting step returns `.finished` or `.failed`, never a pause; a read throws).
public protocol PluginDebugSession: AnyObject, Sendable {
    var supportedCommands: Set<PluginDebugCommand> { get }
    var output: AsyncStream<String> { get }
    func firstStop() async throws -> PluginDebugStop
    func perform(_ command: PluginDebugCommand) async throws -> PluginDebugStop
    func source(of unit: PluginDebugUnit) async throws -> String
    func stack() async throws -> [PluginDebugFrame]
    func variables(inFrame level: Int) async throws -> [PluginDebugVariable]
    // The breakpoint as the engine placed it (its line may move to the next executable one); nil when it cannot be set.
    func setBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws -> PluginDebugBreakpoint?
    func removeBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws
    // Ends the target and rolls back its open transaction, whatever state it is in, and says whether it could confirm
    // that. Returns within 3 seconds: the host closes the session's transport 5 seconds after asking.
    func stop() async -> PluginDebugStopOutcome
}

public struct PluginDebugTarget: Sendable, Hashable {
    public let identity: String
    public let name: String
    public let schema: String?
    public let kindDisplayName: String

    public init(identity: String, name: String, schema: String?, kindDisplayName: String) {
        self.identity = identity
        self.name = name
        self.schema = schema
        self.kindDisplayName = kindDisplayName
    }
}

public struct PluginDebugPlan: Sendable {
    public let target: PluginDebugTarget
    public let entryPoints: [PluginDebugEntryPoint]
    public let mayWrite: Bool
    public let preparation: PluginDebugPreparation?
    // Asked for in the start sheet, never in the connection form, so an off module leaves no field behind.
    public let options: [ConnectionField]
    // What happens to the routine's changes when it runs to the end, shown in the start sheet.
    public let note: String?

    public init(
        target: PluginDebugTarget,
        entryPoints: [PluginDebugEntryPoint],
        mayWrite: Bool,
        preparation: PluginDebugPreparation? = nil,
        options: [ConnectionField] = [],
        note: String? = nil
    ) {
        self.target = target
        self.entryPoints = entryPoints
        self.mayWrite = mayWrite
        self.preparation = preparation
        self.options = options
        self.note = note
    }
}

public struct PluginDebugEntryPoint: Sendable, Hashable {
    public let identity: String
    public let displayName: String
    public let parameters: [PluginDebugParameter]

    public init(identity: String, displayName: String, parameters: [PluginDebugParameter]) {
        self.identity = identity
        self.displayName = displayName
        self.parameters = parameters
    }
}

public struct PluginDebugParameter: Sendable, Hashable {
    public let name: String
    public let typeName: String
    public let mode: PluginDebugParameterMode
    public let hasDefault: Bool

    public init(name: String, typeName: String, mode: PluginDebugParameterMode, hasDefault: Bool) {
        self.name = name
        self.typeName = typeName
        self.mode = mode
        self.hasDefault = hasDefault
    }
}

public enum PluginDebugParameterMode: String, Sendable, Hashable {
    case input
    case output
    case inputOutput
    case variadic
}

// Statements the host runs, after the user confirms, before the session can start (Oracle's compile for debug).
public struct PluginDebugPreparation: Sendable {
    public let message: String
    public let informativeText: String?
    public let actionTitle: String
    public let statements: [String]

    public init(message: String, informativeText: String?, actionTitle: String, statements: [String]) {
        self.message = message
        self.informativeText = informativeText
        self.actionTitle = actionTitle
        self.statements = statements
    }
}

public struct PluginDebugRequest: Sendable {
    public let entryPoint: PluginDebugEntryPoint
    public let arguments: [PluginDebugArgument]
    public let breakpoints: [PluginDebugBreakpoint]
    public let optionValues: [String: String]

    public init(
        entryPoint: PluginDebugEntryPoint,
        arguments: [PluginDebugArgument],
        breakpoints: [PluginDebugBreakpoint],
        optionValues: [String: String] = [:]
    ) {
        self.entryPoint = entryPoint
        self.arguments = arguments
        self.breakpoints = breakpoints
        self.optionValues = optionValues
    }
}

public struct PluginDebugArgument: Sendable, Hashable {
    public let parameterName: String
    public let value: PluginDebugArgumentValue

    public init(parameterName: String, value: PluginDebugArgumentValue) {
        self.parameterName = parameterName
        self.value = value
    }
}

public enum PluginDebugArgumentValue: Sendable, Hashable {
    case text(String)
    case null
    case defaultValue
}

public enum PluginDebugCommand: String, Sendable, Hashable {
    case continueExecution
    case stepOver
    case stepInto
    case stepOut
}

public enum PluginDebugStopOutcome: Sendable {
    case ended
    // The target may still be running on the server; the message names it and how to end it.
    case unconfirmed(message: String, detail: String?)
}

public enum PluginDebugStop: Sendable {
    case paused(PluginDebugLocation)
    case finished(PluginQueryResult?)
    case failed(message: String, detail: String?)
}

public struct PluginDebugUnit: Sendable, Hashable {
    public let identity: String
    public let displayName: String

    public init(identity: String, displayName: String) {
        self.identity = identity
        self.displayName = displayName
    }
}

// `line` is 1-based in the text `source(of:)` returns for `unit`.
public struct PluginDebugLocation: Sendable, Hashable {
    public let unit: PluginDebugUnit
    public let line: Int

    public init(unit: PluginDebugUnit, line: Int) {
        self.unit = unit
        self.line = line
    }
}

public struct PluginDebugBreakpoint: Sendable, Hashable {
    public let unitIdentity: String
    public let line: Int

    public init(unitIdentity: String, line: Int) {
        self.unitIdentity = unitIdentity
        self.line = line
    }
}

public struct PluginDebugFrame: Sendable, Hashable {
    public let level: Int
    public let location: PluginDebugLocation?
    public let arguments: String?

    public init(level: Int, location: PluginDebugLocation?, arguments: String?) {
        self.level = level
        self.location = location
        self.arguments = arguments
    }
}

public struct PluginDebugVariable: Sendable, Hashable {
    public let name: String
    public let kind: PluginDebugVariableKind
    public let typeName: String?
    // Nil is SQL NULL.
    public let value: String?
    public let isConstant: Bool

    public init(name: String, kind: PluginDebugVariableKind, typeName: String?, value: String?, isConstant: Bool) {
        self.name = name
        self.kind = kind
        self.typeName = typeName
        self.value = value
        self.isConstant = isConstant
    }
}

public enum PluginDebugVariableKind: String, Sendable, Hashable {
    case argument
    case local
    case package
}
