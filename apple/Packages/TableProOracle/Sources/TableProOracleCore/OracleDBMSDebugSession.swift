import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "OracleDBMSDebugSession")

// DBMS_DEBUG: the target runs the routine in debug mode and the supervisor drives it through DBMS_DEBUG calls. Both
// are client connections, so it works through every transport the app has, where JDWP needs the server to reach
// this Mac. Oracle documents it as deprecated since 12.2; it works on 23.26 (measured).
public actor OracleDBMSDebugSession: OracleDebugEngine {
    nonisolated public let mechanism = OracleDebugMechanism.dbmsDebug
    // break_any_return stops in the caller after the return (measured from a depth-3 frame).
    nonisolated public let supportsStepOut = true
    nonisolated public let notices: AsyncStream<OracleDebugNotice>
    private let noticeContinuation: AsyncStream<OracleDebugNotice>.Continuation

    private enum State {
        case ready
        case running
        case paused
        case ended
    }

    // What the supervisor last heard from the target. A wait whose answer never came or did not read leaves it unknown:
    // the target may then be paused, waiting for the supervisor, while no step shows it.
    private enum TargetPosition {
        case running
        case paused
        case unknown
    }

    private struct BreakpointKey: Hashable {
        let unit: OracleDebugUnit
        let line: Int
    }

    private struct VisibleFrame {
        let location: OracleDebugLocation
        let subprogram: String?
        // GET_VALUE's frame number: 0 for the running frame, else the PRINT_BACKTRACE index.
        let valueFrame: Int
    }

    private typealias Statements = OracleDBMSDebugStatements

    private let target: any OracleDebugChannel
    private let supervisor: any OracleDebugChannel
    private let entryPoint: OracleDebugEntryPoint
    private let invocation: OracleDebugStatements.Invocation
    private let callEndWait: Duration

    private var state = State.ready
    private var targetPosition = TargetPosition.running
    private var call: Task<Result<[String?], Error>, Never>?
    private var lastEvent: Statements.Event?
    private var placed: [BreakpointKey: Int] = [:]
    private var pending: Set<BreakpointKey> = []
    private var holds = OracleDebugBreakpointHolds()
    private var lineMaps: [OracleDebugUnit: [Int]] = [:]
    private var scans: [OracleDebugUnit: OraclePLSQLDeclarationScan] = [:]
    private var pinger: Task<Void, Never>?
    private var isDriving = false
    private var stopRequested = false
    private var isStopped = false
    private var gaveUp = false
    private var stopResult = OracleDebugStopResult.ended
    private var targetIdentity: OracleDebugSessionIdentity?
    private var callEnded = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        target: any OracleDebugChannel,
        supervisor: any OracleDebugChannel,
        entryPoint: OracleDebugEntryPoint,
        invocation: OracleDebugStatements.Invocation,
        callEndWait: Duration = OracleDebugSupport.callEndWait,
        notices initial: [OracleDebugNotice]
    ) {
        self.target = target
        self.supervisor = supervisor
        self.entryPoint = entryPoint
        self.invocation = invocation
        self.callEndWait = callEndWait
        (notices, noticeContinuation) = AsyncStream.makeStream(of: OracleDebugNotice.self)
        for notice in initial {
            noticeContinuation.yield(notice)
        }
    }

    // DEBUG_ON takes effect after its own call, so the next PL/SQL the target runs is the routine.
    func start(breakpoints: [(unit: OracleDebugUnit, line: Int)]) async throws {
        let debugID = "TP" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        targetIdentity = await OracleDebugSupport.sessionIdentity(of: target)
        let setup = Statements.targetSetup(debugID: debugID)
        _ = try await target.executeDirect(setup.block, binds: setup.binds)
        _ = try await supervisor.executeDirect(Statements.ownSchema)
        let attach = Statements.attach(debugID: debugID)
        _ = try await supervisor.executeDirect(attach.block, binds: attach.binds)
        for breakpoint in breakpoints {
            _ = try await setBreakpoint(in: breakpoint.unit, line: breakpoint.line, atStart: true)
        }
    }

    // MARK: - Running

    public func firstStop() async throws -> OracleDebugStop {
        guard state == .ready else { throw OracleDebugError.notPaused }
        if stopRequested { return .failed(.stopped) }
        state = .running
        let target = target
        let invocation = invocation
        let call = Task { () -> Result<[String?], Error> in
            do {
                return .success(try await target.executeDirect(invocation.block, binds: invocation.binds, readsRows: true))
            } catch {
                return .failure(error)
            }
        }
        self.call = call
        Task { [weak self] in
            _ = await call.value
            await self?.markCallEnded()
        }
        isDriving = true
        defer { isDriving = false }
        return try await stoppedOnError { try await driveToEntry() }
    }

    private func driveToEntry() async throws -> OracleDebugStop {
        var event = try await wait(flags: nil)
        guard event.isPause else { return await conclude() }
        let (entryBreakpoints, entryLines) = try await placeEntryBreakpoints()
        for key in pending {
            pending.remove(key)
            if let number = try await placeNow(key) {
                placed[key] = number
            } else {
                holds.drop(key.line, in: key.unit)
                noticeContinuation.yield(.breakpointHasNoCode(unit: key.unit, line: key.line))
            }
        }
        if entryBreakpoints.isEmpty {
            event = try await stepToEntry(from: event)
        } else {
            // A person's breakpoint on the same header line can be the number that answers.
            func isEntry(_ event: Statements.Event) -> Bool {
                if entryBreakpoints.contains(event.breakpoint ?? -1) { return true }
                guard let location = location(of: event) else { return false }
                return location.unit == entryPoint.entry.unit && entryLines.contains(location.line)
            }
            repeat {
                event = try await wait(flags: Statements.BreakFlags.breakpointsOnly)
            } while event.isPause && !isEntry(event) && !stopRequested
            let userNumbers = Set(placed.values)
            let temporary = entryBreakpoints.subtracting(userNumbers)
            if event.isPause, !temporary.isEmpty {
                _ = try await supervisor.executeDirect(Statements.deleteBreakpoints(temporary.sorted()))
            }
        }
        return await settle(event)
    }

    // The header line of every overload with the entry point's name; DBMS_DEBUG accepts a breakpoint there and stops
    // before the declarations run (measured).
    private func placeEntryBreakpoints() async throws -> (numbers: Set<Int>, lines: Set<Int>) {
        let unit = entryPoint.entry.unit
        let headers: [Int]
        if entryPoint.entry.isPackaged {
            headers = try await scan(of: unit).headerLines(ofSubprogramNamed: entryPoint.entry.subprogram)
        } else {
            headers = [1]
        }
        let executable = try await executableLines(of: unit)
        var numbers: Set<Int> = []
        var lines: Set<Int> = []
        for header in headers {
            guard let line = executable.first(where: { $0 >= header }) else { continue }
            lines.insert(line)
            let fields = try await OracleDebugSupport.payload(Statements.setBreakpoint(unit: unit, line: line), on: supervisor)
            let answer = try Statements.breakpointAnswer(fromPayload: fields)
            if answer.status == Statements.Status.success, let number = answer.number {
                numbers.insert(number)
            }
        }
        return (numbers, lines)
    }

    // Without a header line to stop at, step into calls until the entry point's own frame runs.
    private func stepToEntry(from start: Statements.Event) async throws -> Statements.Event {
        var event = start
        for _ in 0..<10_000 where event.isPause && !stopRequested {
            event = try await wait(flags: Statements.BreakFlags.anyCall)
            if let top = event.backtrace.last, top.unit == entryPoint.entry.unit,
               !entryPoint.entry.isPackaged || top.entryPoint?.uppercased() == entryPoint.entry.subprogram {
                break
            }
        }
        return event
    }

    public func perform(_ command: OracleDebugCommand) async throws -> OracleDebugStop {
        guard state == .paused, !stopRequested else {
            if stopRequested { return .failed(.stopped) }
            throw OracleDebugError.notPaused
        }
        state = .running
        isDriving = true
        defer { isDriving = false }
        let flags: Int
        switch command {
        case .continueExecution: flags = Statements.BreakFlags.breakpointsOnly
        case .stepOver: flags = Statements.BreakFlags.nextLine
        case .stepInto: flags = Statements.BreakFlags.anyCall
        case .stepOut: flags = Statements.BreakFlags.anyReturn
        }
        return try await stoppedOnError { await settle(try await wait(flags: flags)) }
    }

    // A call Stop overlapped ends as stopped, whatever its own statements reported after the drivers closed.
    private func stoppedOnError(_ body: () async throws -> OracleDebugStop) async throws -> OracleDebugStop {
        do {
            return try await body()
        } catch {
            if stopRequested { return await outcomeOfStop() }
            throw error
        }
    }

    // A stop in the anonymous block that called the entry point has nothing to show, so it runs on.
    private func settle(_ start: Statements.Event) async -> OracleDebugStop {
        var event = start
        while event.isPause, !stopRequested, location(of: event) == nil {
            guard let next = try? await wait(flags: Statements.BreakFlags.breakpointsOnly) else { break }
            event = next
        }
        if stopRequested, event.isPause {
            _ = try? await resume(flags: Statements.BreakFlags.abortExecution)
        }
        guard event.isPause, !stopRequested, let location = location(of: event) else {
            return await conclude()
        }
        lastEvent = event
        state = .paused
        return .paused(location)
    }

    // One supervisor wait lasts `supervisorTimeoutSeconds`; between waits it checks for Stop and for the routine
    // having ended, which a SYNCHRONIZE after the target finished would otherwise wait out.
    private func wait(flags: Int?) async throws -> Statements.Event {
        var event = try await resume(flags: flags)
        while event.timedOut {
            if gaveUp || callEnded || isStopped {
                return event
            }
            event = try await resume(flags: nil)
        }
        if stopRequested, !isStopped, event.isPause {
            event = try await resume(flags: Statements.BreakFlags.abortExecution)
        }
        return event
    }

    private func resume(flags: Int?) async throws -> Statements.Event {
        targetPosition = .unknown
        let fields = try await OracleDebugSupport.payload(Statements.resume(flags: flags), on: supervisor)
        let event = try Statements.event(fromPayload: fields)
        targetPosition = event.isPause ? .paused : .running
        // Here, not where a step reports its pause: a step that fails after the target paused leaves `state` running.
        if event.isPause, !stopRequested {
            startPinging()
        }
        return event
    }

    private func markCallEnded() {
        callEnded = true
    }

    private func location(of event: Statements.Event) -> OracleDebugLocation? {
        guard let top = event.backtrace.last, let unit = top.unit, let line = event.line ?? top.line, line > 0 else {
            return nil
        }
        return OracleDebugLocation(unit: unit, line: line)
    }

    private func conclude() async -> OracleDebugStop {
        stopPinging()
        if stopRequested {
            return await outcomeOfStop()
        }
        let result: Result<[String?], Error>?
        if let call {
            result = await OracleDebugSupport.value(of: call, within: OracleDebugStopBudget.seconds(callEndWait))
        } else {
            result = .failure(OracleDebugError.ended)
        }
        var stop = await OracleDebugSupport.conclude(
            result,
            stopped: stopRequested,
            entryPoint: entryPoint,
            target: target,
            targetIdentity: targetIdentity
        ) { [noticeContinuation] in noticeContinuation.yield($0) }
        if gaveUp {
            stop = .failed(.stillRunning(targetIdentity))
        }
        _ = try? await supervisor.executeDirect(Statements.detach)
        state = .ended
        noticeContinuation.finish()
        return stop
    }

    // Stop owns the cleanup and the drivers are the host's once it returns, so a waiting call only reports its result.
    private func outcomeOfStop() async -> OracleDebugStop {
        if !isStopped {
            await withCheckedContinuation { stopWaiters.append($0) }
        }
        return gaveUp ? .failed(.stillRunning(targetIdentity)) : .failed(.stopped)
    }

    // MARK: - Keeping the target alive

    // The target aborts itself after `targetTimeoutSeconds` without a word from the supervisor, which is what ends it
    // if the app goes away. PING keeps it waiting while a person reads a pause.
    private func startPinging() {
        guard pinger == nil else { return }
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Statements.pingIntervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pingIfPaused()
            }
        }
    }

    private func stopPinging() {
        pinger?.cancel()
        pinger = nil
    }

    private func pingIfPaused() async {
        guard targetPosition == .paused, !isDriving, !stopRequested else { return }
        do {
            _ = try await supervisor.executeDirect(Statements.ping)
        } catch {
            logger.notice("DBMS_DEBUG ping failed: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - Breakpoints

    // A call Stop overlaps keeps the supervisor's gate until it finishes, then ends with Stop, not with what it read or
    // failed to read from a closing connection.
    private func readable<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard !stopRequested else { throw OracleDebugError.ended }
        let value: T
        do {
            value = try await body()
        } catch {
            if stopRequested { throw OracleDebugError.ended }
            throw error
        }
        if stopRequested { throw OracleDebugError.ended }
        return value
    }

    public func setBreakpoint(in unit: OracleDebugUnit, line: Int) async throws -> Int? {
        try await setBreakpoint(in: unit, line: line, atStart: false)
    }

    private func setBreakpoint(in unit: OracleDebugUnit, line: Int, atStart: Bool) async throws -> Int? {
        guard state != .ended else { throw OracleDebugError.ended }
        guard let landed = try await readable({ try await placeBreakpoint(in: unit, line: line) }) else { return nil }
        holds.hold(landed, in: unit, by: atStart ? line : landed)
        return landed
    }

    private func placeBreakpoint(in unit: OracleDebugUnit, line: Int) async throws -> Int? {
        let lines = try await executableLines(of: unit)
        guard let resolved = lines.first(where: { $0 >= line }) else { return nil }
        let key = BreakpointKey(unit: unit, line: resolved)
        if placed[key] != nil || pending.contains(key) { return resolved }
        // Before the target starts there is nothing for SET_BREAKPOINT to talk to.
        guard state == .paused else {
            pending.insert(key)
            return resolved
        }
        guard let number = try await placeNow(key) else { return nil }
        placed[key] = number
        return resolved
    }

    private func placeNow(_ key: BreakpointKey) async throws -> Int? {
        let fields = try await OracleDebugSupport.payload(
            Statements.setBreakpoint(unit: key.unit, line: key.line),
            on: supervisor
        )
        let answer = try Statements.breakpointAnswer(fromPayload: fields)
        guard answer.status == Statements.Status.success else { return nil }
        return answer.number
    }

    public func removeBreakpoint(in unit: OracleDebugUnit, line: Int) async throws {
        guard let landed = holds.release(line, in: unit) else { return }
        let key = BreakpointKey(unit: unit, line: landed)
        pending.remove(key)
        guard let number = placed.removeValue(forKey: key), state == .paused else { return }
        do {
            try await readable {
                _ = try await supervisor.executeDirect(Statements.deleteBreakpoints([number]))
            }
        } catch {
            // Still set on the server, so removing it again has to find it.
            holds.hold(landed, in: unit, by: line)
            placed[key] = number
            throw error
        }
    }

    private func executableLines(of unit: OracleDebugUnit) async throws -> [Int] {
        if let lines = lineMaps[unit] { return lines }
        let lines = try await OracleDebugSupport.executableLines(of: unit, on: supervisor) ?? []
        lineMaps[unit] = lines
        return lines
    }

    // MARK: - Inspection

    public func source(of unit: OracleDebugUnit) async throws -> String {
        try await readable { try await OracleDebugSupport.source(of: unit, on: supervisor) }
    }

    private func scan(of unit: OracleDebugUnit) async throws -> OraclePLSQLDeclarationScan {
        if let scan = scans[unit] { return scan }
        let scan = OraclePLSQLDeclarationScan(source: try await source(of: unit))
        scans[unit] = scan
        return scan
    }

    private var visibleFrames: [VisibleFrame] {
        guard let event = lastEvent else { return [] }
        var frames: [VisibleFrame] = []
        let count = event.backtrace.count
        for (offset, frame) in event.backtrace.enumerated().reversed() {
            guard let unit = frame.unit else { continue }
            let isTop = offset == count - 1
            let line = isTop ? (event.line ?? frame.line ?? 0) : (frame.line ?? 0)
            frames.append(VisibleFrame(
                location: OracleDebugLocation(unit: unit, line: line),
                subprogram: frame.entryPoint,
                valueFrame: isTop ? 0 : offset + 1
            ))
        }
        return frames
    }

    public func stack() async throws -> [OracleDebugFrame] {
        guard !stopRequested else { throw OracleDebugError.ended }
        guard state == .paused else { throw OracleDebugError.notPaused }
        return visibleFrames.enumerated().map { level, frame in
            OracleDebugFrame(level: level, location: frame.location, subprogram: frame.subprogram)
        }
    }

    public func variables(inFrame level: Int) async throws -> [OracleDebugVariable] {
        guard state == .paused else { throw OracleDebugError.notPaused }
        return try await readable { try await readVariables(inFrame: level) }
    }

    private func readVariables(inFrame level: Int) async throws -> [OracleDebugVariable] {
        let frames = visibleFrames
        guard frames.indices.contains(level) else { return [] }
        let frame = frames[level]
        let unit = frame.location.unit
        let candidates = (try? await scan(of: unit))?.candidates(atLine: frame.location.line) ?? []
        var requests = candidates.map { Statements.ValueRequest(name: $0.name, frame: frame.valueFrame) }
        var package: [(declaration: OraclePLSQLDeclarationScan.Declaration, unit: OracleDebugUnit)] = []
        if unit.kind == .packageBody || unit.kind == .package {
            for kind in [OracleDebugUnitKind.packageBody, .package] {
                let owner = OracleDebugUnit(owner: unit.owner, name: unit.name, kind: kind)
                for declaration in (try? await scan(of: owner))?.packageVariables ?? [] {
                    package.append((declaration, owner))
                    requests.append(Statements.ValueRequest(name: declaration.name, package: owner))
                }
            }
        }
        guard !requests.isEmpty else { return [] }
        let fields = try await OracleDebugSupport.payload(Statements.values(requests), on: supervisor)
        let answers = try Statements.valueAnswers(fromPayload: fields, count: requests.count)
        var result: [OracleDebugVariable] = []
        for (index, answer) in answers.enumerated() {
            guard let value = Statements.value(status: answer.status, text: answer.value) else { continue }
            let declaration = index < candidates.count ? candidates[index] : package[index - candidates.count].declaration
            let kind: OracleDebugVariableKind
            if index >= candidates.count {
                kind = .package
            } else {
                kind = declaration.kind == .parameter ? .argument : .local
            }
            result.append(OracleDebugVariable(
                name: declaration.name,
                kind: kind,
                typeName: declaration.typeText,
                value: value,
                isConstant: declaration.kind == .constant
            ))
        }
        return result
    }

    // MARK: - Stop

    // At a pause, abort_execution ends the routine with ORA-06543 and its work rolls back (measured). While it runs,
    // the target reads nothing the supervisor sends, abort included (measured: SET_BREAKPOINT and the abort both
    // timed out and the routine ran to its end), so Stop waits for its next stop or its end, for a bounded time.
    // A step that failed may have left it paused, where only the abort ends it without ALTER SYSTEM.
    public func stop() async -> OracleDebugStopResult {
        if stopRequested {
            if !isStopped {
                await withCheckedContinuation { stopWaiters.append($0) }
            }
            return stopResult
        }
        stopRequested = true
        stopPinging()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: OracleDebugStopBudget.total)
        let endBy = deadline - OracleDebugStopBudget.cleanup
        if let call {
            var ended: Bool
            if targetPosition != .running, !isDriving {
                // A read Stop overlaps holds the supervisor's gate first; the abort waits for it at most half the budget.
                await bounded(by: clock.now.advanced(by: OracleDebugStopBudget.total / 2), closing: supervisor) { _ in
                    _ = try? await self.resume(flags: Statements.BreakFlags.abortExecution)
                }
                ended = await callEnds(call, before: clock.now.advanced(by: .seconds(1)))
                if !ended {
                    ended = await OracleDebugStopBudget.endRunningTarget(clock: clock, budget: clock.now.duration(to: endBy)) {
                        await killTarget(within: clock.now.duration(to: endBy))
                    } waitForEnd: { remaining in
                        await callEnds(call, before: clock.now.advanced(by: remaining))
                    }
                }
            } else {
                ended = await OracleDebugStopBudget.endRunningTarget(clock: clock) {
                    await killTarget(within: clock.now.duration(to: endBy))
                } waitForEnd: { remaining in
                    await callEnds(call, before: clock.now.advanced(by: remaining))
                }
            }
            ended = ended || callEnded
            if ended {
                await bounded(by: deadline, closing: target) { target in
                    _ = try? await target.executeDirect("ROLLBACK")
                }
            } else {
                gaveUp = true
            }
            stopResult = ended ? .ended : .unconfirmed(targetIdentity)
        } else {
            // Before the routine ran, the target only switched debug mode on; it holds no work.
            stopResult = .ended
        }
        if !isDriving {
            await bounded(by: deadline, closing: supervisor) { supervisor in
                _ = try? await supervisor.executeDirect(Statements.detach)
            }
        }
        state = .ended
        noticeContinuation.finish()
        isStopped = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return stopResult
    }

    private func callEnds(_ call: Task<Result<[String?], Error>, Never>, before deadline: ContinuousClock.Instant) async -> Bool {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return callEnded }
        return await OracleDebugSupport.value(of: call, within: OracleDebugStopBudget.seconds(remaining)) != nil
    }

    // A statement that would run past the budget has its channel closed, which is what ends it.
    private func bounded(
        by deadline: ContinuousClock.Instant,
        closing connection: any OracleDebugChannel,
        _ body: @escaping @Sendable (any OracleDebugChannel) async -> Void
    ) async {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        _ = try? await withOracleTimeout(
            seconds: OracleDebugStopBudget.seconds(remaining),
            onTimeout: { connection.cancelCurrentQuery() }
        ) {
            await body(connection)
        }
    }

    // The supervisor waits at most `supervisorTimeoutSeconds` on the gate behind its own poll.
    private func killTarget(within budget: Duration) async -> OracleDebugStopBudget.KillOutcome {
        await OracleDebugSupport.kill(targetIdentity, from: supervisor, within: OracleDebugStopBudget.seconds(budget))
    }
}
