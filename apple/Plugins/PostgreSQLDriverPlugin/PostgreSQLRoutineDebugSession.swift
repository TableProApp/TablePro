//
//  PostgreSQLRoutineDebugSession.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProPluginKit
import TableProPostgreSQLCore

// The target session runs the routine and blocks for the whole run; the proxy session drives it through pldbgapi.
// Every proxy call goes through that connection's serial queue, so nothing reaches the proxy while a step waits:
// client traffic then ends the debugger.
actor PostgreSQLRoutineDebugSession: PluginDebugSession {
    private enum Phase {
        case starting
        case paused
        case running
        case broken
        case ended
    }

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "RoutineDebugSession")
    private static let attachRetryDelay = Duration.milliseconds(300)
    private static let cancelRetryDelay = Duration.milliseconds(250)
    // stop() must return within 3 s, and the host closes every driver as soon as it does, so all of ending the
    // target, a rescue session included, fits in this.
    private static let stopBudget = Duration.milliseconds(2_500)

    nonisolated let supportedCommands = PostgreSQLRoutineDebugProtocol.supportedCommands
    nonisolated let output: AsyncStream<String>

    private let target: PostgreSQLPluginDriver
    private let proxy: PostgreSQLPluginDriver
    private let sessions: any PluginDebugSessionSource
    private let routine: PostgreSQLDebugRoutine
    private let extensionSchema: String
    private let targetProcess: Int?
    private let initialBreakpoints: [PluginDebugBreakpoint]
    private let outputContinuation: AsyncStream<String>.Continuation
    private let rendezvous = PostgreSQLDebugRendezvous()
    // Settled the moment stop() is asked, so a read or breakpoint call it overlaps returns at once, and on every
    // other way the run ends, so no wait on it outlives the session.
    private let stopSignal = PostgreSQLDebugRendezvous()

    private var phase = Phase.starting
    private var hasReportedFirstStop = false
    private var lastStop: PluginDebugLocation?
    private var selectedFrame = 0
    private var port: Int?
    private var handle: Int?
    private var targetCall: Task<Result<PluginQueryResult, Error>, Never>?
    private var terminalStop: PluginDebugStop?
    private var stopRequested = false
    private var stopTask: Task<Void, Never>?
    private var stopDeadline: ContinuousClock.Instant?
    private var abortSent = false
    // The target read an abort: through the proxy, or through a session that attached to it.
    private var abortDelivered = false
    private var proxyInterrupted = false
    private var endedByInterruption = false

    init(
        target: PostgreSQLPluginDriver,
        proxy: PostgreSQLPluginDriver,
        sessions: any PluginDebugSessionSource,
        routine: PostgreSQLDebugRoutine,
        extensionSchema: String,
        targetProcess: Int?,
        breakpoints: [PluginDebugBreakpoint]
    ) {
        self.target = target
        self.proxy = proxy
        self.sessions = sessions
        self.routine = routine
        self.extensionSchema = extensionSchema
        self.targetProcess = targetProcess
        self.initialBreakpoints = breakpoints
        let (stream, continuation) = AsyncStream<String>.makeStream()
        output = stream
        outputContinuation = continuation
    }

    // Sends the call on the target, waits for the PLDBGBREAK notice it raises on entering the routine, and
    // attaches the proxy to the backend number that notice names.
    func start(_ call: PostgreSQLDebugCall) async throws {
        let rendezvous = rendezvous
        let continuation = outputContinuation
        let target = target
        target.core.observeServerNotices { notice in
            if let port = PostgreSQLRoutineDebugProtocol.debuggerPort(inNotice: notice.message) {
                rendezvous.deliver(port: port)
            } else {
                continuation.yield(notice.text)
            }
        }
        targetCall = Task {
            let outcome: Result<PluginQueryResult, Error>
            do {
                outcome = .success(try await target.executeParameterized(query: call.sql, parameters: call.parameters))
            } catch {
                outcome = .failure(error)
            }
            target.core.observeServerNotices(nil)
            continuation.finish()
            rendezvous.settle()
            return outcome
        }

        let delivered = await withTaskCancellationHandler {
            await rendezvous.port()
        } onCancel: {
            Self.cancelUntilEntered(target: target, rendezvous: rendezvous, until: .now + Self.stopBudget)
        }
        switch PostgreSQLRoutineDebugProtocol.startStep(port: delivered, isCancelled: Task.isCancelled || stopRequested) {
        case .endedBeforeEntry:
            try await endBeforeEntry()
        case .cancelled:
            phase = .ended
            stopSignal.settle()
            if rendezvous.isAbandoned {
                throw PostgreSQLRoutineDebugError.targetAbandoned(process: targetProcess, port: nil)
            }
            _ = await targetCall?.value
            throw CancellationError()
        case .attachAndAbort(let announced):
            port = announced
            throw await stopForStart(otherwise: CancellationError())
        case .attach(let announced):
            port = announced
            do {
                handle = try await Self.attach(using: proxy, port: announced, extensionSchema: extensionSchema)
                phase = .paused
            } catch {
                phase = .broken
                Self.logger.error("Attaching to the debug target failed: \(error.localizedDescription, privacy: .private)")
                throw await stopForStart(otherwise: PostgreSQLRoutineDebugProtocol.startFailure(
                    error,
                    database: routine.database,
                    routineName: routine.displayName
                ))
            }
            // The attach does not observe cancellation, so a start cancelled meanwhile is ended here, as Stop would.
            if Task.isCancelled {
                throw await stopForStart(otherwise: CancellationError())
            }
        }
    }

    // A backend that may still hold its locks matters more than why the start failed.
    private func stopForStart(otherwise error: Error) async -> Error {
        guard case .unconfirmed = await stop() else { return error }
        return PostgreSQLRoutineDebugError.targetAbandoned(process: targetProcess, port: port)
    }

    // A cancel reaches only a call libpq has already sent, so it is repeated until the call ends or the target
    // announces its port; from then on the target ignores a cancel and the attach and abort end it. A target that
    // neither ends nor announces itself by the deadline is given up, so nothing waits on it forever.
    private static func cancelUntilEntered(
        target: PostgreSQLPluginDriver,
        rendezvous: PostgreSQLDebugRendezvous,
        until deadline: ContinuousClock.Instant
    ) {
        Task.detached {
            while PostgreSQLRoutineDebugProtocol.startCancellation(
                portDelivered: rendezvous.hasPort,
                callEnded: rendezvous.hasSettled
            ) == .cancelCall {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else {
                    logger.fault("The debug target neither ended nor reached the routine before the stop deadline")
                    rendezvous.abandon()
                    return
                }
                target.core.cancelQuery()
                try? await Task.sleep(for: min(cancelRetryDelay, remaining))
            }
        }
    }

    // The call ended before the routine was entered: its arguments were refused, the debugger could not start,
    // or the start was cancelled.
    private func endBeforeEntry() async throws {
        let outcome = await targetCall?.value ?? .failure(CancellationError())
        phase = .ended
        stopSignal.settle()
        hasReportedFirstStop = true
        if case .failure(let error) = outcome {
            if error is CancellationError { throw CancellationError() }
            throw PostgreSQLRoutineDebugProtocol.startFailure(
                error,
                database: routine.database,
                routineName: routine.displayName
            )
        }
        terminalStop = PostgreSQLRoutineDebugProtocol.end(of: outcome, stopRequested: false)
    }

    func firstStop() async throws -> PluginDebugStop {
        if let terminalStop { return terminalStop }
        if stopRequested { return await outcomeAfterStop() }
        if hasReportedFirstStop, phase == .paused, let lastStop { return .paused(lastStop) }
        guard phase == .paused, let handle else { throw PostgreSQLRoutineDebugError.notPaused }
        return try await advance(
            PostgreSQLRoutineDebugProtocol.waitStatement(extensionSchema: extensionSchema, session: handle),
            placing: initialBreakpoints
        )
    }

    func perform(_ command: PluginDebugCommand) async throws -> PluginDebugStop {
        if let terminalStop { return terminalStop }
        if stopRequested { return await outcomeAfterStop() }
        guard phase == .paused, hasReportedFirstStop, let handle else { throw PostgreSQLRoutineDebugError.notPaused }
        guard let statement = PostgreSQLRoutineDebugProtocol.stepStatement(
            command,
            extensionSchema: extensionSchema,
            session: handle
        ) else {
            throw PostgreSQLRoutineDebugError.unsupportedCommand
        }
        return try await advance(statement)
    }

    private func advance(
        _ statement: String,
        placing breakpoints: [PluginDebugBreakpoint] = []
    ) async throws -> PluginDebugStop {
        phase = .running
        selectedFrame = 0
        let reply: PluginQueryResult
        // The target keeps its debugger socket for the rest of its session, so when the routine returns without
        // pausing again the proxy only hears of it once that session closes (measured: 8 s later, on disconnect).
        // The target's own call ending is the signal instead.
        let proxy = proxy
        guard let answered = await rendezvous.reply(to: Task { try await proxy.execute(query: statement) }) else {
            return await targetEnded()
        }
        do {
            reply = try answered.get()
        } catch {
            switch PostgreSQLRoutineDebugProtocol.proxyFailure(error) {
            case .targetEnded:
                return await targetEnded()
            case .interrupted:
                // The target goes on to its next pause and waits for a command the session can no longer match to
                // a reply, so it is ended the way Stop ends it.
                noteInterruption()
                endedByInterruption = !stopRequested
                Self.logger.error("A signal interrupted the debugger session while it waited; ending the target")
                await endTarget()
                return await targetEnded()
            case .broken:
                phase = .broken
                Self.logger.error("The debugger session failed: \(error.localizedDescription, privacy: .private)")
                guard stopRequested else { throw error }
                await endTarget()
                return await outcomeAfterStop()
            }
        }
        hasReportedFirstStop = true
        guard let stop = PostgreSQLRoutineDebugProtocol.location(
            fromBreakpointRow: reply.rows.first?.map(\.asText) ?? []
        ) else {
            return await targetEnded()
        }
        phase = .paused
        lastStop = stop
        if stopRequested {
            // The target paused before the cancel reached it, and a paused target holds a cancel until it resumes.
            await endTarget()
            return await targetEnded()
        }
        if let handle {
            for breakpoint in breakpoints where !stopRequested {
                do {
                    _ = try await place(breakpoint, session: handle)
                } catch where PostgreSQLRoutineDebugProtocol.proxyFailure(error) == .interrupted {
                    noteInterruption()
                    endedByInterruption = !stopRequested
                    await endTarget()
                    return await targetEnded()
                } catch {
                    continue
                }
            }
        }
        if stopRequested { return await outcomeAfterStop() }
        return .paused(stop)
    }

    // MARK: - Reading the paused target

    func source(of unit: PluginDebugUnit) async throws -> String {
        guard let oid = PostgreSQLRoutineDebugProtocol.oid(inIdentity: unit.identity) else {
            throw PostgreSQLRoutineDebugError.routineNotFound(unit.displayName)
        }
        guard !stopRequested else { throw CancellationError() }
        switch phase {
        case .starting, .running:
            throw PostgreSQLRoutineDebugError.notPaused
        case .broken:
            throw PostgreSQLRoutineDebugError.unavailable
        case .paused where hasReportedFirstStop:
            let schema = extensionSchema
            let reply = try await pausedRead {
                PostgreSQLRoutineDebugProtocol.sourceStatement(extensionSchema: schema, session: $0, oid: oid)
            }
            if let text = reply?.rows.first?.first?.asText { return text }
        case .paused:
            break
        case .ended:
            // The proxy may still be waiting on a target that returned; the target's own session is free again.
            guard !rendezvous.isAbandoned else { throw PostgreSQLRoutineDebugError.unavailable }
            let reply = try await target.execute(query: PostgreSQLRoutineDebugProtocol.routineSourceStatement(oid: oid))
            guard let text = reply.rows.first?.first?.asText else {
                throw PostgreSQLRoutineDebugError.routineNotFound(unit.displayName)
            }
            return text
        }
        // pldbg_get_source sends prosrc, which the catalog answers too while the proxy is idle.
        let reply = try await proxyCall(PostgreSQLRoutineDebugProtocol.routineSourceStatement(oid: oid))
        guard let text = reply.rows.first?.first?.asText else {
            throw PostgreSQLRoutineDebugError.routineNotFound(unit.displayName)
        }
        return text
    }

    func stack() async throws -> [PluginDebugFrame] {
        let schema = extensionSchema
        guard let reply = try await pausedRead({
            PostgreSQLRoutineDebugProtocol.stackStatement(extensionSchema: schema, session: $0)
        }) else { return [] }
        return reply.rows.compactMap { PostgreSQLRoutineDebugProtocol.frame(fromStackRow: $0.map(\.asText)) }
    }

    func variables(inFrame level: Int) async throws -> [PluginDebugVariable] {
        let schema = extensionSchema
        if level != selectedFrame {
            guard try await pausedRead({
                PostgreSQLRoutineDebugProtocol.selectFrameStatement(extensionSchema: schema, session: $0, level: level)
            }) != nil else { return [] }
            selectedFrame = level
        }
        guard let reply = try await pausedRead({
            PostgreSQLRoutineDebugProtocol.variablesStatement(extensionSchema: schema, session: $0)
        }) else { return [] }
        return reply.rows.compactMap { PostgreSQLRoutineDebugProtocol.variable(fromRow: $0.map(\.asText)) }
    }

    func setBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws -> PluginDebugBreakpoint? {
        guard let handle = try pausedSession() else { return nil }
        do {
            return try await place(breakpoint, session: handle)
        } catch is CancellationError {
            throw CancellationError()
        } catch where PostgreSQLRoutineDebugProtocol.proxyFailure(error) == .targetEnded {
            return nil
        } catch {
            if PostgreSQLRoutineDebugProtocol.proxyFailure(error) == .interrupted { noteInterruption() }
            throw error
        }
    }

    func removeBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws {
        guard let oid = PostgreSQLRoutineDebugProtocol.oid(inIdentity: breakpoint.unitIdentity) else { return }
        let schema = extensionSchema
        _ = try await pausedRead {
            PostgreSQLRoutineDebugProtocol.dropBreakpointStatement(
                extensionSchema: schema,
                session: $0,
                oid: oid,
                line: breakpoint.line
            )
        }
    }

    // pldbg_set_breakpoint accepts any line and answers t; a line with no statement never stops.
    private func place(_ breakpoint: PluginDebugBreakpoint, session: Int) async throws -> PluginDebugBreakpoint? {
        guard let oid = PostgreSQLRoutineDebugProtocol.oid(inIdentity: breakpoint.unitIdentity), breakpoint.line > 0 else {
            return nil
        }
        let reply = try await proxyCall(PostgreSQLRoutineDebugProtocol.setBreakpointStatement(
            extensionSchema: extensionSchema,
            session: session,
            oid: oid,
            line: breakpoint.line
        ))
        return PostgreSQLCatalogBoolean.isTrue(reply.rows.first?.first?.asText) ? breakpoint : nil
    }

    // A read or breakpoint edit that stop() overlaps throws at once. Its statement still finishes on the proxy
    // first, and the abort queued behind it reaches the target after it: libpq runs one statement at a time per
    // connection, and cancelling the read gains nothing (measured: the cancel lands only once the read's reply has
    // crossed, while it can leave part of that reply unread).
    private func proxyCall(_ statement: String) async throws -> PluginQueryResult {
        let proxy = proxy
        guard let answered = await stopSignal.reply(to: Task { try await proxy.execute(query: statement) }) else {
            throw CancellationError()
        }
        return try answered.get()
    }

    private func pausedRead(_ statement: (Int) -> String) async throws -> PluginQueryResult? {
        guard let handle = try pausedSession() else { return nil }
        do {
            return try await proxyCall(statement(handle))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            switch PostgreSQLRoutineDebugProtocol.proxyFailure(error) {
            case .targetEnded:
                return nil
            case .interrupted:
                noteInterruption()
                throw error
            case .broken:
                throw error
            }
        }
    }

    // The interrupted call's reply stays unread on the proxy, so no later call could be matched to its own reply.
    private func noteInterruption() {
        phase = .broken
        proxyInterrupted = true
    }

    // pldbgapi answers only while the target waits for a command; the session is nil once the target is gone.
    private func pausedSession() throws -> Int? {
        if stopRequested { return nil }
        switch phase {
        case .paused where hasReportedFirstStop:
            return handle
        case .ended, .broken:
            return nil
        case .starting, .running, .paused:
            throw PostgreSQLRoutineDebugError.notPaused
        }
    }

    // MARK: - Stop

    func stop() async -> PluginDebugStopOutcome {
        if stopTask == nil {
            stopRequested = true
            stopSignal.settle()
            if stopDeadline == nil { stopDeadline = .now + Self.stopBudget }
            stopTask = Task { await performStop() }
        }
        await stopTask?.value
        // A call that failed on its own connection ended only on this side; the backend may still hold its locks.
        let callEnded = rendezvous.hasSettled && (abortDelivered || !target.hasLostConnection)
        return PostgreSQLRoutineDebugProtocol.stopOutcome(
            callEnded: callEnded,
            abandoned: rendezvous.isAbandoned,
            process: targetProcess,
            port: port
        )
    }

    private func performStop() async {
        switch phase {
        case .starting:
            if port == nil {
                let deadline = currentDeadline()
                Self.cancelUntilEntered(target: target, rendezvous: rendezvous, until: deadline)
                let rendezvous = rendezvous
                port = await Self.bounded(by: deadline) { await rendezvous.port() } ?? nil
            }
            if port != nil {
                await endTarget()
            } else {
                await awaitTargetEnd()
            }
        case .paused, .broken:
            await endTarget()
        case .running:
            // Never the proxy: cancelling a waiting proxy call desynchronizes the session. A target that paused
            // before this cancel arrived holds it, and the step in flight aborts the target instead.
            target.core.cancelQueryKeepingReply()
            await awaitTargetEnd()
        case .ended:
            break
        }
        // The backend of a call whose connection dropped may still wait for a debugger, and only an attach reaches it.
        if target.hasLostConnection, !abortDelivered {
            await abortByAttaching(reusingProxy: false, evenAfterTheCallEnded: true)
        }
        _ = await targetEnded()
    }

    private func currentDeadline() -> ContinuousClock.Instant {
        if let stopDeadline { return stopDeadline }
        let fresh = ContinuousClock.now + Self.stopBudget
        stopDeadline = fresh
        return fresh
    }

    // The abort is sent, not waited on: an abort to a target that already returned waits on a socket that stays
    // open for the target's session. The target's call ending is what counts. Without a working proxy the target may
    // still be running a statement, which only a cancel ends before it pauses and waits in accept() for good; a
    // paused target holds the cancel and a waiting one ignores it.
    private func endTarget() async {
        if proxyInterrupted || phase == .broken { target.core.cancelQueryKeepingReply() }
        Task { await self.abortTarget() }
        await awaitTargetEnd()
    }

    // Past the deadline the target is given up rather than waited on: the host closes the drivers once stop()
    // returns, and the answer then says the backend may still hold its locks.
    private func awaitTargetEnd() async {
        let rendezvous = rendezvous
        guard await Self.bounded(by: currentDeadline(), { await rendezvous.settled() }) == nil, !rendezvous.hasSettled else {
            return
        }
        Self.logger.fault("The debug target was not confirmed ended before the stop deadline")
        rendezvous.abandon()
    }

    private func abortTarget() async {
        guard !abortSent else { return }
        abortSent = true
        // After an interruption the same proxy still holds the target, which reads the abort at its next pause.
        if let handle, phase != .broken || proxyInterrupted {
            let proxy = proxy
            let statement = PostgreSQLRoutineDebugProtocol.abortStatement(extensionSchema: extensionSchema, session: handle)
            switch await Self.boundedResult(by: currentDeadline(), { try await proxy.execute(query: statement) }) {
            case .success?:
                abortDelivered = true
                return
            case .failure(let error)?:
                // An interrupted abort was still written; the target reads it at its next pause while the proxy
                // stays connected (measured), and an attach cannot reach a target the proxy still holds.
                guard PostgreSQLRoutineDebugProtocol.proxyFailure(error) == .broken else { return }
                Self.logger.error("Abort through the debugger session failed: \(error.localizedDescription, privacy: .private)")
            case nil:
                return
            }
        }
        await abortByAttaching(reusingProxy: handle == nil && phase != .broken)
    }

    // A target whose proxy is gone waits in accept() and ignores cancel and terminate. Attaching to its backend
    // number and aborting is the only way to end it. The old proxy can hold the target for a moment after its
    // client goes, so the attach is retried until the deadline.
    private func abortByAttaching(reusingProxy: Bool, evenAfterTheCallEnded: Bool = false) async {
        guard let port else { return }
        let driver: PostgreSQLPluginDriver
        if reusingProxy {
            driver = proxy
        } else {
            let sessions = sessions
            switch await Self.boundedResult(by: currentDeadline(), {
                try await PostgreSQLPluginDriver.debugSession(from: sessions)
            }) {
            case .success(let opened)?:
                driver = opened
            case .failure(let error)?:
                Self.logger.error("No session to reach the debug target: \(error.localizedDescription, privacy: .private)")
                return
            case nil:
                Self.logger.error("A session to reach the debug target did not open before the stop deadline")
                return
            }
        }
        let schema = extensionSchema
        let deadline = currentDeadline()
        while !abortDelivered, evenAfterTheCallEnded || !rendezvous.hasSettled {
            let ended = await Self.boundedResult(by: deadline) {
                let session = try await Self.attach(using: driver, port: port, extensionSchema: schema)
                _ = try await driver.execute(
                    query: PostgreSQLRoutineDebugProtocol.abortStatement(extensionSchema: schema, session: session)
                )
            }
            switch ended {
            case .success?:
                abortDelivered = true
                return
            case nil:
                return
            case .failure:
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { return }
                try? await Task.sleep(for: min(Self.attachRetryDelay, remaining))
            }
        }
    }

    private static func attach(using driver: PostgreSQLPluginDriver, port: Int, extensionSchema: String) async throws -> Int {
        let reply = try await driver.execute(
            query: PostgreSQLRoutineDebugProtocol.attachStatement(extensionSchema: extensionSchema, port: port)
        )
        guard let session = reply.rows.first?.first?.asText.flatMap({ Int($0) }) else {
            throw PostgreSQLRoutineDebugError.unavailable
        }
        return session
    }

    // The operation keeps running past the deadline; its result is then dropped.
    private static func bounded<T: Sendable>(
        by deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resume = { @Sendable (value: T?) in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task { resume(await operation()) }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                resume(nil)
            }
        }
    }

    private static func boundedResult<T: Sendable>(
        by deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error>? {
        await bounded(by: deadline) { () async -> Result<T, Error> in
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
    }

    private func targetEnded() async -> PluginDebugStop {
        await rendezvous.settled()
        phase = .ended
        stopSignal.settle()
        if let terminalStop { return terminalStop }
        let stop: PluginDebugStop
        if rendezvous.isAbandoned {
            stop = PostgreSQLRoutineDebugProtocol.abandonedStop(process: targetProcess, port: port)
        } else {
            let outcome = await targetCall?.value ?? .failure(CancellationError())
            stop = PostgreSQLRoutineDebugProtocol.end(
                of: outcome,
                stopRequested: stopRequested,
                interrupted: endedByInterruption
            )
        }
        if terminalStop == nil { terminalStop = stop }
        return terminalStop ?? stop
    }

    private func outcomeAfterStop() async -> PluginDebugStop {
        await stopTask?.value
        return terminalStop ?? PostgreSQLRoutineDebugProtocol.end(of: .failure(CancellationError()), stopRequested: true)
    }
}
