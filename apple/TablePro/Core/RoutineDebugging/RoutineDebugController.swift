//
//  RoutineDebugController.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os
import TableProPluginKit

extension PluginDebugCommand {
    static let hostCommands: [PluginDebugCommand] = [.continueExecution, .stepOver, .stepInto, .stepOut]
}

internal struct RoutineDebugStartChoice: Sendable {
    let entryPoint: PluginDebugEntryPoint
    let arguments: [PluginDebugArgument]
    let optionValues: [String: String]
}

// One debug run. Session calls never overlap except `stop()`: every other call waits its turn in `lastOperation`.
// ObservableObject rather than @Observable, which needs macOS 14.
@MainActor
internal final class RoutineDebugController: ObservableObject {
    enum State {
        case preparing
        case starting
        case running
        case paused(PluginDebugLocation)
        case finished(PluginQueryResult?)
        case failed(String)
        // The plugin's own words when a waiting step answered the stop, which can say the routine still runs on the server.
        case stopped(String?)

        var isTerminal: Bool {
            switch self {
            case .finished, .failed, .stopped: true
            case .preparing, .starting, .running, .paused: false
            }
        }

        var pausedLocation: PluginDebugLocation? {
            if case .paused(let location) = self { return location }
            return nil
        }

        var endedByItself: Bool {
            switch self {
            case .finished, .failed: true
            case .preparing, .starting, .running, .paused, .stopped: false
            }
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "RoutineDebugController")
    private static let outputLineLimit = 5_000
    // Output a plugin relays as the routine completes (Oracle's DBMS_OUTPUT) comes through its own task, shortly after.
    private static let outputDrainLimit: Duration = .seconds(1)
    static let stopNotConfirmed = String(
        localized: "The debugger didn't confirm the stop. The routine may still be running on the server."
    )

    let plan: PluginDebugPlan
    let choice: RoutineDebugStartChoice
    let connectionId: UUID
    let databaseType: DatabaseType

    @Published private(set) var state: State = .preparing
    @Published private(set) var isStopping = false
    @Published private(set) var supportedCommands: Set<PluginDebugCommand> = []
    @Published private(set) var frames: [PluginDebugFrame] = []
    @Published private(set) var selectedFrameLevel: Int?
    // The frame whose source and variables are on screen; they always change together.
    @Published private(set) var displayedFrameLevel: Int?
    // False while a pause's stack is still loading: the list then shows the previous stack, which cannot be chosen from.
    @Published private(set) var stackIsCurrent = false
    @Published private(set) var variables: [PluginDebugVariable] = []
    @Published private(set) var outputLines: [String] = []
    @Published private(set) var displayedUnit: PluginDebugUnit?
    @Published private(set) var sources: [String: String] = [:]
    // What the ribbon shows: placed breakpoints plus edits waiting for the next pause.
    @Published private(set) var breakpoints: [String: Set<Int>] = [:]
    @Published private(set) var inspectionError: String?
    @Published private(set) var resultGrid: HeldRowsGridAdapter?

    var cursorLine: Int?
    // Set by the coordinator: the user declined to start, so the tab has nothing to show.
    var onCancelled: (@MainActor () -> Void)?

    private let debugger: any PluginRoutineDebugging
    private let sessionSource: RoutineDebugSessionSource
    private let gate: any ExecutionGate
    private let confirmPreparation: @MainActor (PluginDebugPreparation) async -> Bool
    private let withdrawPreparation: @MainActor () -> Void
    private let cancelLimit: Duration
    private var session: (any PluginDebugSession)?
    private var startTask: Task<any PluginDebugSession, Error>?
    private var preparationTask: Task<Void, Error>?
    private var authorizationTask: Task<OperationDecision, Never>?
    private var placedBreakpoints: [String: Set<Int>] = [:]
    private var lastOperation: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopDeadline: RoutineDebugStopDeadline?
    // The one `stop()` call a session gets, shared by everything that ends its target.
    private var targetStop: Task<PluginDebugStopOutcome, Never>?
    // The plugin could not confirm its target ended, or did not answer by the deadline: the status says so.
    private var unconfirmedStop: String?
    private var outputTask: Task<Void, Never>?
    private var pauseGeneration = 0
    private var stopMessage: String?
    // `isEnding` from the moment the run starts to end; `hasEnded` once its drivers are closed and its state final.
    private var isEnding = false
    private(set) var hasEnded = false
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        plan: PluginDebugPlan,
        choice: RoutineDebugStartChoice,
        connectionId: UUID,
        databaseType: DatabaseType,
        debugger: any PluginRoutineDebugging,
        sessionSource: RoutineDebugSessionSource,
        gate: any ExecutionGate = ExecutionGateProvider.shared,
        cancelLimit: Duration = RoutineDebugSessions.defaultStopTimeout,
        confirmPreparation: @escaping @MainActor (PluginDebugPreparation) async -> Bool,
        withdrawPreparation: @escaping @MainActor () -> Void = {}
    ) {
        self.plan = plan
        self.choice = choice
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.debugger = debugger
        self.sessionSource = sessionSource
        self.gate = gate
        self.confirmPreparation = confirmPreparation
        self.withdrawPreparation = withdrawPreparation
        self.cancelLimit = cancelLimit
    }

    // MARK: - Commands

    func canPerform(_ command: PluginDebugCommand) -> Bool {
        guard !isStopping, state.pausedLocation != nil else { return false }
        return supportedCommands.contains(command)
    }

    func perform(_ command: PluginDebugCommand) {
        guard canPerform(command), let session else { return }
        setState(.running)
        enqueue { [weak self] in
            guard let self, !self.isStopping else { return }
            // An edit made while the pause was still loading had its own sync skipped once this left the pause.
            await self.syncBreakpoints(session)
            guard !self.isStopping else { return }
            await self.runStep { try await session.perform(command) }
        }
    }

    var canStop: Bool {
        !isEnding && !isStopping
    }

    // Every way a run is stopped comes here: Stop, its tab or window closing, a disconnect or reconnect, the module
    // turned off, quit. A caller that waits on the stop passes its deadline so both end at the same instant.
    func stop(by deadline: RoutineDebugStopDeadline? = nil) {
        guard canStop else { return }
        isStopping = true
        let deadline = startStopDeadline(deadline)
        notifyStateChange()
        if case .preparing = state {
            withdrawPreparation()
        }
        if let session {
            stopTask = Task {
                await self.endTarget(session)
                await self.end(.stopped(nil))
            }
        } else if let startTask {
            cancelStart(startTask, by: deadline)
        } else if let preparationTask {
            cancelPreparation(preparationTask, by: deadline)
        } else if let authorizationTask {
            cancelAuthorization(authorizationTask, by: deadline)
        } else if lastOperation == nil {
            Task { await self.end(.stopped(nil)) }
        }
        // Otherwise the preparation question is up or the run is between two steps, and it ends itself as stopped at
        // its next check.
    }

    private func startStopDeadline(_ requested: RoutineDebugStopDeadline? = nil) -> RoutineDebugStopDeadline {
        if let stopDeadline {
            return stopDeadline
        }
        let deadline = requested ?? RoutineDebugStopDeadline(after: cancelLimit)
        stopDeadline = deadline
        return deadline
    }

    // The only place a session hears `stop()`: at once, even over a read, an edit or a step still running, which the
    // plugin then ends itself. Returns when the plugin answers or at the deadline, whichever comes first.
    private func endTarget(_ session: any PluginDebugSession) async {
        let deadline = startStopDeadline()
        let stopping: Task<PluginDebugStopOutcome, Never>
        if let targetStop {
            stopping = targetStop
        } else {
            let source = sessionSource
            stopping = Task {
                // A plugin may need one more session to end its target, which the connection's admission fence must not refuse.
                await source.permitCleanup()
                return await session.stop()
            }
            targetStop = stopping
        }
        let answered = await deadline.wait { _ = await stopping.value }
        guard answered else {
            Self.logger.warning("Debug target did not answer its stop by the deadline; closing its connections")
            unconfirmedStop = Self.stopNotConfirmed
            return
        }
        if case .unconfirmed(let message, let detail) = await stopping.value {
            unconfirmedStop = Self.join(message, detail)
        }
    }

    // The target may already be running its call before `startDebug` returns. Cancelling makes the plugin end it, and a
    // session it returns anyway is stopped within the same deadline; one that never answers loses its drivers then.
    private func cancelStart(_ start: Task<any PluginDebugSession, Error>, by deadline: RoutineDebugStopDeadline) {
        let source = sessionSource
        stopTask = Task {
            await source.permitCleanup()
            start.cancel()
            let answered = await deadline.wait { _ = await start.result }
            guard !answered else { return }
            Self.logger.warning("Debug start ignored its cancellation; closing its drivers")
            self.unconfirmedStop = Self.stopNotConfirmed
            await self.end(.stopped(nil))
        }
    }

    // The gate withdraws its prompt when cancelled and answers as a Cancel would; one that cannot is not waited on past
    // the deadline, since nothing is open yet that the run would have to close.
    private func cancelAuthorization(_ work: Task<OperationDecision, Never>, by deadline: RoutineDebugStopDeadline) {
        stopTask = Task {
            work.cancel()
            let answered = await deadline.wait { _ = await work.value }
            guard !answered else { return }
            await self.end(.stopped(nil))
        }
    }

    // A statement already sent cannot be called back: the run waits for it until the deadline, then closes its
    // connection, which abandons it. Either way the run ends stopped and never goes on to start the session.
    private func cancelPreparation(_ work: Task<Void, Error>, by deadline: RoutineDebugStopDeadline) {
        stopTask = Task {
            work.cancel()
            let answered = await deadline.wait { _ = await work.result }
            guard !answered else { return }
            Self.logger.warning("Debug preparation still running at the deadline; closing its connection")
            await self.end(.stopped(nil))
        }
    }

    func waitUntilEnded() async {
        guard !hasEnded else { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    // MARK: - Breakpoints

    var hasBreakpoints: Bool {
        breakpoints.values.contains { !$0.isEmpty }
    }

    // Toggle Breakpoint acts on the caret's line of the source on screen, and nothing once the run is ending.
    var canToggleBreakpoint: Bool {
        !isEnding && displayedUnit != nil && cursorLine != nil
    }

    var canRemoveAllBreakpoints: Bool {
        !isEnding && hasBreakpoints
    }

    var displayedBreakpointLines: Set<Int> {
        guard let unit = displayedUnit else { return [] }
        return breakpoints[unit.identity] ?? []
    }

    func toggleBreakpointAtCursor() {
        guard canToggleBreakpoint, let cursorLine else { return }
        toggleBreakpoint(atLine: cursorLine)
    }

    func toggleBreakpoint(atLine line: Int) {
        guard let unit = displayedUnit, line > 0, !isEnding else { return }
        if breakpoints[unit.identity]?.contains(line) == true {
            breakpoints[unit.identity]?.remove(line)
        } else {
            breakpoints[unit.identity, default: []].insert(line)
        }
        scheduleBreakpointSync()
    }

    func removeAllBreakpoints() {
        guard canRemoveAllBreakpoints else { return }
        breakpoints = [:]
        scheduleBreakpointSync()
    }

    // While running the engine may not take a breakpoint, so edits wait for the next pause.
    private func scheduleBreakpointSync() {
        guard let session, state.pausedLocation != nil, !isStopping else { return }
        enqueue { [weak self] in
            guard let self, self.state.pausedLocation != nil, !self.isStopping else { return }
            await self.syncBreakpoints(session)
        }
    }

    private func syncBreakpoints(_ session: any PluginDebugSession) async {
        let units = Set(breakpoints.keys).union(placedBreakpoints.keys)
        for unit in units.sorted() {
            let wanted = breakpoints[unit] ?? []
            let placed = placedBreakpoints[unit] ?? []
            for line in placed.subtracting(wanted).sorted() {
                guard !isStopping else { return }
                do {
                    try await session.removeBreakpoint(PluginDebugBreakpoint(unitIdentity: unit, line: line))
                    placedBreakpoints[unit]?.remove(line)
                } catch {
                    // A stop ends the call on purpose; that is no failure to show.
                    guard !isStopping else { return }
                    breakpoints[unit, default: []].insert(line)
                    inspectionError = Self.message(for: error)
                }
            }
            for line in wanted.subtracting(placed).sorted() {
                guard !isStopping else { return }
                let requested = PluginDebugBreakpoint(unitIdentity: unit, line: line)
                do {
                    let result = try await session.setBreakpoint(requested)
                    if let result {
                        placedBreakpoints[result.unitIdentity, default: []].insert(result.line)
                    }
                    // Removed while the request was out: the server's breakpoint stays placed but unwanted, so the
                    // next sync takes it off instead of the marker coming back.
                    guard breakpoints[unit]?.contains(line) == true else { continue }
                    breakpoints[unit]?.remove(line)
                    if let result {
                        breakpoints[result.unitIdentity, default: []].insert(result.line)
                    }
                } catch {
                    guard !isStopping else { return }
                    breakpoints[unit]?.remove(line)
                    inspectionError = Self.message(for: error)
                }
            }
        }
    }

    // MARK: - Frames

    var currentLocation: PluginDebugLocation? {
        guard let paused = state.pausedLocation else { return nil }
        let shown = frames.first { $0.level == displayedFrameLevel }
        return shown?.location ?? paused
    }

    var executionLine: Int? {
        guard let location = currentLocation, location.unit.identity == displayedUnit?.identity else { return nil }
        return location.line
    }

    var displayedSource: String {
        displayedUnit.flatMap { sources[$0.identity] } ?? ""
    }

    func selectFrame(level: Int) {
        guard let session, state.pausedLocation != nil, stackIsCurrent, selectedFrameLevel != level,
              let frame = frames.first(where: { $0.level == level })
        else { return }
        selectedFrameLevel = level
        let generation = pauseGeneration
        enqueue { [weak self] in
            guard let self, self.isCurrentFrame(level, generation) else { return }
            do {
                if let unit = frame.location?.unit {
                    try await self.loadSource(of: unit, from: session)
                }
                guard self.isCurrentFrame(level, generation) else { return }
                let values = try await session.variables(inFrame: level)
                guard self.isCurrentFrame(level, generation) else { return }
                self.show(frame: level, unit: frame.location?.unit, variables: values)
            } catch {
                guard !self.isStopping else { return }
                self.inspectionError = Self.message(for: error)
            }
        }
    }

    private func isCurrentFrame(_ level: Int, _ generation: Int) -> Bool {
        isCurrentPause(generation) && selectedFrameLevel == level
    }

    private func show(frame level: Int, unit: PluginDebugUnit?, variables values: [PluginDebugVariable]) {
        if let unit {
            displayedUnit = unit
        }
        variables = values
        displayedFrameLevel = level
    }

    // MARK: - Status

    var statusText: String {
        if isStopping, !hasEnded {
            return String(localized: "Stopping…")
        }
        switch state {
        case .preparing:
            return String(localized: "Preparing…")
        case .starting:
            return String(localized: "Starting…")
        case .running:
            return String(localized: "Running…")
        case .paused(let location):
            return String(format: String(localized: "Paused at line %d in %@"), location.line, location.unit.displayName)
        case .finished:
            return String(localized: "Finished")
        case .failed(let message):
            return message
        case .stopped(let message):
            return message ?? String(localized: "Stopped")
        }
    }

    // MARK: - Run

    func start() {
        guard lastOperation == nil, !isEnding else { return }
        lastOperation = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        let decision = await authorize(OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: nil,
            kind: plan.mayWrite ? .writeQuery : .readQuery,
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: String(localized: "Debug Routine")
        ))
        guard await proceed(after: decision) else { return }
        if let preparation = plan.preparation {
            guard await prepare(preparation) else { return }
        }
        guard !isStopping else {
            await end(.stopped(nil))
            return
        }
        setState(.starting)
        let request = PluginDebugRequest(
            entryPoint: choice.entryPoint,
            arguments: choice.arguments,
            breakpoints: breakpoints.flatMap { unit, lines in
                lines.map { PluginDebugBreakpoint(unitIdentity: unit, line: $0) }
            },
            optionValues: choice.optionValues
        )
        let debugger = debugger
        let sessionSource = sessionSource
        let start = Task { try await debugger.startDebug(request, sessions: sessionSource) }
        startTask = start
        let session: any PluginDebugSession
        do {
            session = try await start.value
            startTask = nil
        } catch {
            startTask = nil
            if !isStopping {
                Self.logger.error("Debug session did not start: \(error.publicLogShape, privacy: .public)")
            }
            await end(isStopping ? .stopped(nil) : .failed(Self.message(for: error)))
            return
        }
        // Stopped while starting: a session that came back anyway is ended before its drivers close.
        guard !isStopping, !isEnding else {
            await endTarget(session)
            await end(.stopped(nil))
            return
        }
        self.session = session
        placedBreakpoints = request.breakpoints.reduce(into: [:]) { placed, breakpoint in
            placed[breakpoint.unitIdentity, default: []].insert(breakpoint.line)
        }
        supportedCommands = session.supportedCommands
        observeOutput(of: session)
        await runStep { try await session.firstStop() }
    }

    // In a task of its own, so a stop can withdraw a confirmation or Touch ID prompt the gate is still waiting on.
    private func authorize(_ request: OperationRequest) async -> OperationDecision {
        let gate = gate
        let work = Task { await gate.authorize(request) }
        authorizationTask = work
        defer { authorizationTask = nil }
        return await work.value
    }

    private func proceed(after decision: OperationDecision) async -> Bool {
        switch decision {
        case .authorized:
            guard isStopping else { return true }
            await end(.stopped(nil))
            return false
        case .denied(let reason, let cause):
            if cause == .cancelledByUser || isStopping {
                let declined = !isStopping
                await end(.stopped(nil))
                if declined {
                    onCancelled?()
                }
            } else {
                await end(.failed(reason))
            }
            return false
        }
    }

    private func prepare(_ preparation: PluginDebugPreparation) async -> Bool {
        guard await confirmPreparation(preparation) else {
            let declined = !isStopping
            await end(.stopped(nil))
            if declined {
                onCancelled?()
            }
            return false
        }
        guard !isStopping else {
            await end(.stopped(nil))
            return false
        }
        let decision = await authorize(OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: preparation.statements.joined(separator: "\n"),
            kind: .schemaMutation,
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: preparation.actionTitle
        ))
        guard await proceed(after: decision) else { return false }
        let statements = preparation.statements
        let source = sessionSource
        let work = Task { try await source.run(statements) }
        preparationTask = work
        do {
            try await work.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            await end(isStopping ? .stopped(nil) : .failed(Self.message(for: error)))
            return false
        }
        guard !isStopping else {
            await end(.stopped(nil))
            return false
        }
        return true
    }

    private func runStep(_ step: @escaping () async throws -> PluginDebugStop) async {
        let outcome: PluginDebugStop
        do {
            outcome = try await step()
        } catch {
            guard !isStopping, let session else { return }
            Self.logger.error("Debug step failed: \(error.publicLogShape, privacy: .public)")
            // The step's outcome is unknown, so the target is ended before its drivers close.
            await endTarget(session)
            await end(.failed(Self.message(for: error)))
            return
        }
        // A stop in flight owns the ending; a pause that raced it is the plugin's to abort. The waiting step's own words
        // (rolled back, say) become the status when the stop itself was confirmed.
        guard !isStopping else {
            if case .failed(let message, let detail) = outcome {
                answerStop(with: Self.join(message, detail))
            }
            return
        }
        switch outcome {
        case .paused(let location):
            pauseGeneration += 1
            selectedFrameLevel = nil
            displayedFrameLevel = nil
            stackIsCurrent = false
            // The last pause's values would read as this one's until the new ones load, or for good if they fail.
            variables = []
            inspectionError = nil
            setState(.paused(location))
            await inspect(location, generation: pauseGeneration)
        case .finished(let result):
            await end(.finished(result))
        case .failed(let message, let detail):
            await end(.failed(Self.join(message, detail)))
        @unknown default:
            if let session {
                await endTarget(session)
            }
            await end(.failed(String(localized: "The debugger stopped for a reason TablePro doesn't know.")))
        }
    }

    private func inspect(_ location: PluginDebugLocation, generation: Int) async {
        guard let session else { return }
        inspectionError = nil
        displayedUnit = location.unit
        await syncBreakpoints(session)
        guard isCurrentPause(generation) else { return }
        do {
            try await loadSource(of: location.unit, from: session)
            guard isCurrentPause(generation) else { return }
            let stack = try await session.stack()
            guard isCurrentPause(generation) else { return }
            frames = stack
            let level = stack.first?.level ?? 0
            selectedFrameLevel = level
            stackIsCurrent = true
            let values = try await session.variables(inFrame: level)
            guard isCurrentFrame(level, generation) else { return }
            show(frame: level, unit: location.unit, variables: values)
        } catch {
            guard !isStopping else { return }
            inspectionError = Self.message(for: error)
        }
    }

    private func loadSource(of unit: PluginDebugUnit, from session: any PluginDebugSession) async throws {
        guard sources[unit.identity] == nil else { return }
        sources[unit.identity] = try await session.source(of: unit)
    }

    private func isCurrentPause(_ generation: Int) -> Bool {
        generation == pauseGeneration && state.pausedLocation != nil && !isStopping
    }

    private func observeOutput(of session: any PluginDebugSession) {
        let stream = session.output
        outputTask = Task { [weak self] in
            for await line in stream {
                self?.appendOutput(line)
            }
        }
    }

    private func appendOutput(_ line: String) {
        outputLines.append(line)
        if outputLines.count > Self.outputLineLimit {
            outputLines.removeFirst(outputLines.count - Self.outputLineLimit)
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            await operation()
        }
    }

    private func answerStop(with message: String) {
        stopMessage = message
        if hasEnded, case .stopped(.none) = state {
            setState(.stopped(message))
        }
    }

    private func end(_ final: State) async {
        guard !isEnding else { return }
        isEnding = true
        // A run that ended by itself may still have output on its way, possibly read over these connections; a stopped
        // one keeps what already arrived.
        if !isStopping, let outputTask, final.endedByItself {
            _ = await AppModuleTermination.runCapped(at: Self.outputDrainLimit) {
                await outputTask.value
            }
        }
        await sessionSource.closeAll()
        outputTask?.cancel()
        // Read after the wait: the waiting step's answer to the stop can land while the drivers close.
        var final = final
        switch final {
        case .stopped(.none):
            final = .stopped(unconfirmedStop ?? stopMessage)
        case .failed(let message):
            if let unconfirmedStop {
                final = .failed(Self.join(message, unconfirmedStop))
            }
        default:
            break
        }
        if case .finished(let result) = final {
            resultGrid = result.flatMap { Self.makeResultGrid($0, databaseType: databaseType) }
        }
        hasEnded = true
        setState(final)
        let waiters = endWaiters
        endWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func setState(_ newState: State) {
        state = newState
        notifyStateChange()
    }

    // The toolbar and the Debug menu validate on a window update; a step finishing posts no event to cause one.
    private func notifyStateChange() {
        NSApplication.shared.setWindowsNeedUpdate(true)
    }

    // MARK: - Helpers

    static func message(for error: Error) -> String {
        if let driverError = error as? any PluginDriverError {
            return join(driverError.pluginErrorMessage, driverError.pluginErrorDetail)
        }
        return error.localizedDescription
    }

    private static func join(_ message: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return message }
        return message + "\n" + detail
    }

    private static func makeResultGrid(_ result: PluginQueryResult, databaseType: DatabaseType) -> HeldRowsGridAdapter? {
        guard !result.columns.isEmpty else { return nil }
        let classifier = ColumnTypeClassifier(family: SQLTypeFamily.of(databaseType))
        let rows = TableRows.from(
            queryRows: result.rows,
            columns: result.columns,
            columnTypes: result.columnTypeNames.map { classifier.classify(rawTypeName: $0) }
        )
        var configuration = DataGridConfiguration()
        configuration.traits = DataGridEngineTraits(databaseType: databaseType)
        configuration.showRowNumbers = true
        configuration.supportsValueFilter = false
        configuration.commands = [.freezeColumns, .displayAs]
        let grid = HeldRowsGridAdapter(configuration: configuration, sortsHeldRows: true)
        grid.setRows(rows)
        return grid
    }
}
