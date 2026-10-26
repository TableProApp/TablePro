//
//  RoutineDebugFakes.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport

// How a statement sent to a fake driver behaves: at once, until its task is cancelled, or until a gate opens whatever
// happens to its task (a statement already on the server).
internal enum FakeStatementBehavior: Sendable {
    case immediate
    case untilCancelled
    case untilOpened(AsyncGate)
}

internal final class FakeDebugDriver: PluginDriverStub, @unchecked Sendable {
    private let behavior: FakeStatementBehavior
    private let onExecute: @Sendable () -> Void

    init(behavior: FakeStatementBehavior = .immediate, onExecute: @escaping @Sendable () -> Void = {}) {
        self.behavior = behavior
        self.onExecute = onExecute
    }

    func execute(query: String) async throws -> PluginQueryResult {
        onExecute()
        switch behavior {
        case .immediate:
            break
        case .untilCancelled:
            // Stands for a statement that runs until the run gives up on it.
            try await Task.sleep(for: .seconds(600))
        case .untilOpened(let gate):
            await gate.wait()
        }
        return .empty
    }
}

// Counts what the host does with the drivers a session took, so a test can see every one was closed.
internal final class DebugDriverLog: @unchecked Sendable {
    private let lock = NSLock()
    private let statements: FakeStatementBehavior
    private var opened = 0
    private var closed = 0
    private var executed = 0

    init(statements: FakeStatementBehavior = .immediate) {
        self.statements = statements
    }

    var openedCount: Int { lock.withLock { opened } }
    var closedCount: Int { lock.withLock { closed } }
    var executedCount: Int { lock.withLock { executed } }

    func source(admits: @escaping @Sendable () async -> Bool = { true }) -> RoutineDebugSessionSource {
        RoutineDebugSessionSource(admits: admits) { [self] in
            lock.withLock { opened += 1 }
            let driver = FakeDebugDriver(behavior: statements) { [self] in
                lock.withLock { executed += 1 }
            }
            return RoutineDebugDriverHandle(driver: driver) { [self] in
                lock.withLock { closed += 1 }
            }
        }
    }
}

internal final class FakeDebugSession: PluginDebugSession, @unchecked Sendable {
    static let unit = PluginDebugUnit(identity: "16431", displayName: "order_total(integer)")
    static let source = "BEGIN\n  total := 0;\n  total := total + 1;\n  RETURN total;\nEND"

    let supportedCommands: Set<PluginDebugCommand>
    let output: AsyncStream<String>
    private let outputContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private let stopGate = AsyncGate()
    private let firstStopLine: Int
    private let performBlocksUntilStop: Bool
    private let placesBreakpoint: (Int) -> Int?
    private let stopBlocker: AsyncGate?
    private let stepGate: AsyncGate?
    private let placeGate: AsyncGate?
    private let stopAnswer: PluginDebugStop
    private let inspectGate: AsyncGate?
    private let relayedOutput: (gate: AsyncGate, lines: [String])?
    private let frames: [PluginDebugFrame]
    private let laterStackGate: AsyncGate?
    private let failsLaterVariables: Bool
    private var calls: [String] = []
    private var removedBreakpoints: [PluginDebugBreakpoint] = []
    private var stepInFlight = false
    private var overlaps = 0
    private var callsInFlight = 0
    private var stopOverlaps = 0
    private var stops = 0
    private var performs: [PluginDebugCommand] = []
    private var sourceReads = 0
    private var stackReads = 0
    private var variableReads: [Int] = []
    private var setBreakpoints: [PluginDebugBreakpoint] = []
    private var nextPerformLine: Int

    init(
        supportedCommands: Set<PluginDebugCommand> = [.continueExecution, .stepOver, .stepInto],
        firstStopLine: Int = 2,
        performBlocksUntilStop: Bool = false,
        placesBreakpoint: @escaping (Int) -> Int? = { $0 },
        stopBlocker: AsyncGate? = nil,
        stepGate: AsyncGate? = nil,
        placeGate: AsyncGate? = nil,
        stopAnswer: PluginDebugStop = .finished(nil),
        inspectGate: AsyncGate? = nil,
        relayedOutput: (gate: AsyncGate, lines: [String])? = nil,
        frames: [PluginDebugFrame] = [PluginDebugFrame(level: 0, location: nil, arguments: nil)],
        laterStackGate: AsyncGate? = nil,
        failsLaterVariables: Bool = false
    ) {
        self.supportedCommands = supportedCommands
        self.firstStopLine = firstStopLine
        self.performBlocksUntilStop = performBlocksUntilStop
        self.placesBreakpoint = placesBreakpoint
        self.stopBlocker = stopBlocker
        self.stepGate = stepGate
        self.placeGate = placeGate
        self.stopAnswer = stopAnswer
        self.inspectGate = inspectGate
        self.relayedOutput = relayedOutput
        self.frames = frames
        self.laterStackGate = laterStackGate
        self.failsLaterVariables = failsLaterVariables
        self.nextPerformLine = firstStopLine + 1
        var continuation: AsyncStream<String>.Continuation?
        output = AsyncStream { continuation = $0 }
        outputContinuation = continuation!
    }

    var stopCount: Int { lock.withLock { stops } }
    var performedCommands: [PluginDebugCommand] { lock.withLock { performs } }
    var sourceReadCount: Int { lock.withLock { sourceReads } }
    var stackReadCount: Int { lock.withLock { stackReads } }
    var variableReadLevels: [Int] { lock.withLock { variableReads } }
    var placedBreakpointRequests: [PluginDebugBreakpoint] { lock.withLock { setBreakpoints } }
    var removedBreakpointRequests: [PluginDebugBreakpoint] { lock.withLock { removedBreakpoints } }
    // Steps and breakpoint edits in the order they reached the session.
    var callLog: [String] { lock.withLock { calls } }
    // Calls other than `stop()` that arrived while a step was still waiting, which the contract forbids.
    var overlappingCallCount: Int { lock.withLock { overlaps } }
    // Stops that arrived while a read or a breakpoint edit was still out, which only a waiting step may see.
    var stopOverlapCount: Int { lock.withLock { stopOverlaps } }

    private func beginCall() {
        lock.withLock {
            if stepInFlight { overlaps += 1 }
            callsInFlight += 1
        }
    }

    private func endCall() {
        lock.withLock { callsInFlight -= 1 }
    }

    func emit(_ line: String) {
        outputContinuation.yield(line)
    }

    func firstStop() async throws -> PluginDebugStop {
        .paused(PluginDebugLocation(unit: Self.unit, line: firstStopLine))
    }

    func perform(_ command: PluginDebugCommand) async throws -> PluginDebugStop {
        let line = lock.withLock { () -> Int in
            if stepInFlight { overlaps += 1 }
            stepInFlight = true
            performs.append(command)
            calls.append("perform \(command.rawValue)")
            defer { nextPerformLine += 1 }
            return nextPerformLine
        }
        defer { lock.withLock { stepInFlight = false } }
        await stepGate?.wait()
        if performBlocksUntilStop {
            await stopGate.wait()
            return stopAnswer
        }
        if let relayedOutput {
            // The routine completes, and its output arrives a moment later from another task, as Oracle relays DBMS_OUTPUT.
            let continuation = outputContinuation
            Task {
                await relayedOutput.gate.wait()
                for line in relayedOutput.lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            return .finished(nil)
        }
        return .paused(PluginDebugLocation(unit: Self.unit, line: line))
    }

    func source(of unit: PluginDebugUnit) async throws -> String {
        beginCall()
        defer { endCall() }
        lock.withLock { sourceReads += 1 }
        await inspectGate?.wait()
        return Self.source
    }

    // The first pause's stack comes at once; a later one waits for `laterStackGate`.
    func stack() async throws -> [PluginDebugFrame] {
        beginCall()
        defer { endCall() }
        let read = lock.withLock { () -> Int in
            stackReads += 1
            return stackReads
        }
        if read > 1 {
            await laterStackGate?.wait()
        }
        return frames
    }

    func variables(inFrame level: Int) async throws -> [PluginDebugVariable] {
        beginCall()
        defer { endCall() }
        let read = lock.withLock { () -> Int in
            variableReads.append(level)
            return variableReads.count
        }
        if failsLaterVariables, read > 1 {
            throw RoutineDebugError.unsupported
        }
        return [
            PluginDebugVariable(name: "total", kind: .local, typeName: "integer", value: "0", isConstant: false),
            PluginDebugVariable(name: "note", kind: .local, typeName: "text", value: nil, isConstant: false),
        ]
    }

    func setBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws -> PluginDebugBreakpoint? {
        beginCall()
        defer { endCall() }
        lock.withLock {
            setBreakpoints.append(breakpoint)
            calls.append("set \(breakpoint.line)")
        }
        await placeGate?.wait()
        return placesBreakpoint(breakpoint.line).map {
            PluginDebugBreakpoint(unitIdentity: breakpoint.unitIdentity, line: $0)
        }
    }

    func removeBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws {
        beginCall()
        defer { endCall() }
        lock.withLock {
            removedBreakpoints.append(breakpoint)
            calls.append("remove \(breakpoint.line)")
        }
    }

    func stop() async {
        lock.withLock {
            stops += 1
            if callsInFlight > 0 { stopOverlaps += 1 }
        }
        await stopBlocker?.wait()
        await stopGate.open()
        outputContinuation.finish()
    }
}

internal enum FakeStartBehavior: Sendable {
    case immediate
    // The target's call is under way and waits for a breakpoint that never comes, until the start is cancelled.
    case untilCancelled
    // A plugin that never looks at cancellation and returns its session once the gate opens.
    case ignoringCancellation(AsyncGate)
}

internal final class FakeRoutineDebugger: PluginRoutineDebugging, @unchecked Sendable {
    let session: FakeDebugSession
    private let driversPerSession: Int
    private let startBehavior: FakeStartBehavior
    private let lock = NSLock()
    private var requests: [PluginDebugRequest] = []
    private var cancelled = false

    init(session: FakeDebugSession, driversPerSession: Int = 2, startBehavior: FakeStartBehavior = .immediate) {
        self.session = session
        self.driversPerSession = driversPerSession
        self.startBehavior = startBehavior
    }

    var startRequests: [PluginDebugRequest] { lock.withLock { requests } }
    var startWasCancelled: Bool { lock.withLock { cancelled } }

    var canDebugRoutines: Bool { true }

    func debugTarget(for routine: PluginRoutineInfo) -> PluginDebugTarget? {
        PluginDebugTarget(identity: routine.identity ?? routine.name, name: routine.name, schema: routine.schema, kindDisplayName: "Function")
    }

    func debugTargets(schema: String?) async throws -> [PluginDebugTarget] { [] }

    func prepareDebug(_ target: PluginDebugTarget) async throws -> PluginDebugPlan {
        RoutineDebugFixtures.plan()
    }

    func startDebug(_ request: PluginDebugRequest, sessions: any PluginDebugSessionSource) async throws -> any PluginDebugSession {
        lock.withLock { requests.append(request) }
        for _ in 0..<driversPerSession {
            _ = try await sessions.openSession()
        }
        switch startBehavior {
        case .immediate:
            break
        case .untilCancelled:
            do {
                // Stands for a call that never reaches its first line; only cancellation ends it.
                try await Task.sleep(for: .seconds(600))
            } catch {
                lock.withLock { cancelled = true }
                throw CancellationError()
            }
        case .ignoringCancellation(let gate):
            await gate.wait()
        }
        return session
    }
}

internal enum RoutineDebugFixtures {
    static let target = PluginDebugTarget(identity: "16431", name: "order_total", schema: "public", kindDisplayName: "Function")
    static let entryPoint = PluginDebugEntryPoint(
        identity: "16431",
        displayName: "order_total(integer)",
        parameters: [PluginDebugParameter(name: "id", typeName: "integer", mode: .input, hasDefault: false)]
    )

    static func plan(mayWrite: Bool = false, preparation: PluginDebugPreparation? = nil) -> PluginDebugPlan {
        PluginDebugPlan(target: target, entryPoints: [entryPoint], mayWrite: mayWrite, preparation: preparation)
    }

    @MainActor
    static func controller(
        session: FakeDebugSession = FakeDebugSession(),
        drivers: DebugDriverLog = DebugDriverLog(),
        plan: PluginDebugPlan = RoutineDebugFixtures.plan(),
        gate: any ExecutionGate = AlwaysAllowGate(),
        startBehavior: FakeStartBehavior = .immediate,
        cancelLimit: Duration = .seconds(5),
        admits: @escaping @Sendable () async -> Bool = { true },
        confirmPreparation: @escaping @MainActor (PluginDebugPreparation) async -> Bool = { _ in true },
        withdrawPreparation: @escaping @MainActor () -> Void = {}
    ) -> (RoutineDebugController, FakeRoutineDebugger) {
        let debugger = FakeRoutineDebugger(session: session, startBehavior: startBehavior)
        let controller = RoutineDebugController(
            plan: plan,
            choice: RoutineDebugStartChoice(
                entryPoint: entryPoint,
                arguments: [PluginDebugArgument(parameterName: "id", value: .text("7"))],
                optionValues: [:]
            ),
            connectionId: UUID(),
            databaseType: .postgresql,
            debugger: debugger,
            sessionSource: drivers.source(admits: admits),
            gate: gate,
            cancelLimit: cancelLimit,
            confirmPreparation: confirmPreparation,
            withdrawPreparation: withdrawPreparation
        )
        return (controller, debugger)
    }
}
