import Foundation
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "OracleJDWPDebugSession")

// DBMS_DEBUG_JDWP: the target session connected back to this Mac and is driven over JDWP. Units are classes
// `$Oracle/<Kind>/<OWNER>/<NAME>`, subprograms are methods, the code index is the source line, and every value is an
// object whose `_value` string holds its text (all measured on 23.26).
public actor OracleJDWPDebugSession: OracleDebugEngine {
    nonisolated public let mechanism = OracleDebugMechanism.jdwp
    // SINGLE_STEP with depth OUT returns to the caller (measured).
    nonisolated public let supportsStepOut = true
    nonisolated public let notices: AsyncStream<OracleDebugNotice>
    private let noticeContinuation: AsyncStream<OracleDebugNotice>.Continuation

    private enum Signal {
        // One composite packet: two requests at one location arrive together and are one stop.
        case events([OracleJDWPEvent])
        case callEnded
        case connectionClosed
        // The task waiting for the next signal was cancelled.
        case cancelled
    }

    private enum State {
        case ready
        case running
        case paused
        case ended
    }

    private struct BreakpointKey: Hashable {
        let unit: OracleDebugUnit
        let line: Int
    }

    private struct ClassInfo {
        let id: UInt64
        let unit: OracleDebugUnit?
        var methods: [OracleJDWPMethod]?
        var lineTables: [UInt64: OracleJDWPLineTable] = [:]
    }

    private struct MethodKey: Hashable {
        let classID: UInt64
        let methodID: UInt64
    }

    private struct FrameInfo {
        let id: UInt64
        let location: OracleJDWPLocation
        let resolved: OracleDebugLocation
        let method: OracleJDWPMethod?
    }

    private let connection: OracleJDWPConnection
    private let target: any OracleDebugChannel
    private let helper: any OracleDebugChannel
    private let entryPoint: OracleDebugEntryPoint
    private let invocation: OracleDebugStatements.Invocation
    private let connectCall: Task<Result<[String?], Error>, Never>
    private let targetIdentity: OracleDebugSessionIdentity?
    private let callEndWait: Duration
    private var gaveUp = false
    private var stopResult = OracleDebugStopResult.ended
    private var preparedClasses: Set<UInt64> = []

    private var sizes = OracleJDWPIDSizes.oracle
    private var signals: [Signal] = []
    private var waiter: CheckedContinuation<Signal, Never>?
    private var pump: Task<Void, Never>?
    private var call: Task<Result<[String?], Error>, Never>?
    private var state = State.ready
    private var thread: UInt64 = 1
    private var stopRequested = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopped = false

    private var classes: [UInt64: ClassInfo] = [:]
    private var classIDs: [OracleDebugUnit: UInt64] = [:]
    private var prepareRequests: Set<OracleDebugUnit> = []
    private var placed: [BreakpointKey: Int32] = [:]
    private var pending: Set<BreakpointKey> = []
    private var holds = OracleDebugBreakpointHolds()
    private var entryRequests: Set<Int32> = []
    private var stepRequest: Int32?
    private var frames: [FrameInfo] = []
    private var fieldCache: [UInt64: [OracleJDWPField]] = [:]
    // Method ids are unique only within their class.
    private var variableTables: [MethodKey: [OracleJDWPVariable]] = [:]

    init(
        connection: OracleJDWPConnection,
        target: any OracleDebugChannel,
        helper: any OracleDebugChannel,
        entryPoint: OracleDebugEntryPoint,
        invocation: OracleDebugStatements.Invocation,
        connectCall: Task<Result<[String?], Error>, Never>,
        targetIdentity: OracleDebugSessionIdentity? = nil,
        callEndWait: Duration = OracleDebugSupport.callEndWait,
        notices initial: [OracleDebugNotice]
    ) {
        self.targetIdentity = targetIdentity
        self.callEndWait = callEndWait
        self.connection = connection
        self.target = target
        self.helper = helper
        self.entryPoint = entryPoint
        self.invocation = invocation
        self.connectCall = connectCall
        (notices, noticeContinuation) = AsyncStream.makeStream(of: OracleDebugNotice.self)
        for notice in initial {
            noticeContinuation.yield(notice)
        }
    }

    // The target is suspended at VM_START inside CONNECT_TCP: ask for the classes that matter, then let it return.
    func start(breakpoints: [(unit: OracleDebugUnit, line: Int)]) async throws {
        try await guarded { try await handshakeVM(breakpoints: breakpoints) }
    }

    private func handshakeVM(breakpoints: [(unit: OracleDebugUnit, line: Int)]) async throws {
        let reply = try await connection.send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.idSizes)
        var reader = OracleJDWPReader(reply, sizes: sizes)
        do {
            sizes = try OracleJDWPIDSizes.validated(
                field: try reader.i32(),
                method: try reader.i32(),
                object: try reader.i32(),
                referenceType: try reader.i32(),
                frame: try reader.i32()
            )
        } catch {
            throw OracleDebugError.jdwp(.handshakeFailed)
        }
        startPump()
        try await waitForVMStart()
        try await requestPrepare(of: entryPoint.entry.unit)
        await adoptIfLoaded(entryPoint.entry.unit)
        for breakpoint in breakpoints {
            _ = try await setBreakpoint(in: breakpoint.unit, line: breakpoint.line, atStart: true)
        }
        try await resume()
        switch await connectCall.value {
        case .success: break
        case .failure(let error): throw error
        }
    }

    private func startPump() {
        let commands = connection.commands
        pump = Task { [weak self] in
            for await packet in commands {
                await self?.receive(packet)
            }
            await self?.post(.connectionClosed)
        }
    }

    // An event that does not decode ends the session: closing the socket ends the target with it.
    private func receive(_ packet: OracleJDWPPacket) async {
        guard case let .command(_, commandSet, command, data) = packet,
              commandSet == OracleJDWPCommand.event, command == OracleJDWPCommand.composite else { return }
        do {
            post(.events(try OracleJDWPEventSet.decode(data, sizes: sizes).events))
        } catch {
            logger.error("Could not decode a JDWP event: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
            await connection.close()
        }
    }

    private func post(_ signal: Signal) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: signal)
        } else {
            signals.append(signal)
        }
    }

    private func nextSignal() async -> Signal {
        if !signals.isEmpty { return signals.removeFirst() }
        if Task.isCancelled { return .cancelled }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.post(.cancelled) }
        }
    }

    private func waitForVMStart() async throws {
        let deadline = Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: 10_000_000_000)) != nil else { return }
            await self?.post(.connectionClosed)
        }
        defer { deadline.cancel() }
        while true {
            switch await nextSignal() {
            case .events(let events):
                for case .vmStart(let thread) in events {
                    self.thread = thread
                    return
                }
            case .callEnded, .connectionClosed:
                throw OracleDebugError.jdwp(.handshakeFailed)
            case .cancelled:
                throw CancellationError()
            }
        }
    }

    private func send(_ commandSet: UInt8, _ command: UInt8, _ build: (inout OracleJDWPWriter) -> Void = { _ in }) async throws -> OracleJDWPReader {
        var writer = OracleJDWPWriter(sizes: sizes)
        build(&writer)
        let reply = try await connection.send(commandSet, command, writer.data)
        return OracleJDWPReader(reply, sizes: sizes)
    }

    private func resume() async throws {
        _ = try await connection.send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.resume)
    }

    private func requestPrepare(of unit: OracleDebugUnit) async throws {
        guard !prepareRequests.contains(unit) else { return }
        prepareRequests.insert(unit)
        _ = try await connection.send(
            OracleJDWPCommand.eventRequest,
            OracleJDWPCommand.set,
            OracleJDWPRequest.classPrepare(matching: unit.jdwpClassName, sizes: sizes)
        )
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
            await self?.post(.callEnded)
        }
        return try await stoppedOnError { try await guarded { try await run(untilEntry: true) } }
    }

    public func perform(_ command: OracleDebugCommand) async throws -> OracleDebugStop {
        guard state == .paused, !stopRequested else {
            if stopRequested { return .failed(.stopped) }
            throw OracleDebugError.notPaused
        }
        state = .running
        frames = []
        return try await stoppedOnError {
            try await guarded {
                switch command {
                case .continueExecution:
                    break
                case .stepOver:
                    try await setStep(.over)
                case .stepInto:
                    try await setStep(.into)
                case .stepOut:
                    try await setStep(.out)
                }
                try await resume()
                return try await run(untilEntry: false)
            }
        }
    }

    // A call Stop overlapped ends with Stop, not with what it read or failed to read from a closing connection.
    private func guarded<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard !stopRequested else { throw OracleDebugError.ended }
        let value: T
        do {
            value = try await translated(body)
        } catch {
            if stopRequested { throw OracleDebugError.ended }
            throw error
        }
        if stopRequested { throw OracleDebugError.ended }
        return value
    }

    // Data the peer sent that does not decode ends the session: closing the socket ends the target.
    private func translated<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as OracleDebugError {
            throw error
        } catch OracleJDWPError.malformedPacket, OracleJDWPError.truncated {
            await connection.close()
            throw OracleDebugError.malformedReply
        } catch OracleJDWPError.timedOut {
            throw OracleDebugError.debuggerStoppedAnswering
        } catch OracleJDWPError.closed {
            throw OracleDebugError.ended
        } catch OracleJDWPError.reply(let code) {
            throw OracleDebugError.debuggerRefused(code: code)
        } catch OracleJDWPError.handshakeFailed, OracleJDWPError.unexpectedEvent {
            await connection.close()
            throw OracleDebugError.malformedReply
        }
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

    // Stop owns the ending and the drivers are the host's once it returns, so a waiting call only reports it.
    private func outcomeOfStop() async -> OracleDebugStop {
        if !isStopped {
            await withCheckedContinuation { stopWaiters.append($0) }
        }
        return gaveUp ? .failed(.stillRunning(targetIdentity)) : .failed(.stopped)
    }

    private func setStep(_ depth: OracleJDWPRequest.StepDepth) async throws {
        var reader = OracleJDWPReader(
            try await connection.send(
                OracleJDWPCommand.eventRequest,
                OracleJDWPCommand.set,
                OracleJDWPRequest.step(thread: thread, depth: depth, sizes: sizes)
            ),
            sizes: sizes
        )
        stepRequest = try reader.i32()
    }

    private func clearStep() async {
        guard let request = stepRequest else { return }
        stepRequest = nil
        _ = try? await connection.send(
            OracleJDWPCommand.eventRequest,
            OracleJDWPCommand.clear,
            OracleJDWPRequest.clear(kind: .singleStep, requestID: request, sizes: sizes)
        )
    }

    private func run(untilEntry: Bool) async throws -> OracleDebugStop {
        while true {
            let signal = await nextSignal()
            // The caller gave up on this step: the target ends as Stop ends it.
            if case .cancelled = signal {
                _ = await stop()
                throw CancellationError()
            }
            if stopRequested {
                return await conclude()
            }
            guard case .events(let events) = signal else { return await conclude() }
            if events.contains(.vmDeath) { return await conclude() }
            var requests: Set<Int32> = []
            var stopLocation: OracleJDWPLocation?
            for event in events {
                switch event {
                case .classPrepare(_, let thread, let typeID, let signature):
                    self.thread = thread
                    await prepared(typeID: typeID, signature: signature)
                case .breakpoint(let request, let thread, let location), .singleStep(let request, let thread, let location):
                    self.thread = thread
                    requests.insert(request)
                    stopLocation = stopLocation ?? location
                default:
                    break
                }
            }
            guard let location = stopLocation, !untilEntry || !requests.isDisjoint(with: entryRequests) else {
                try await resume()
                continue
            }
            await clearStep()
            if untilEntry {
                await clearEntryRequests()
            }
            guard let resolved = await resolve(location) else {
                // Our own anonymous block, or code with no source to show: run on.
                try await resume()
                continue
            }
            state = .paused
            return .paused(resolved)
        }
    }

    private func conclude() async -> OracleDebugStop {
        if stopRequested {
            return await outcomeOfStop()
        }
        let result: Result<[String?], Error>?
        if let call {
            result = await OracleDebugSupport.value(of: call, within: OracleDebugStopBudget.seconds(callEndWait))
        } else {
            result = .failure(OracleDebugError.ended)
        }
        let stop = await OracleDebugSupport.conclude(
            result,
            stopped: stopRequested,
            entryPoint: entryPoint,
            target: target,
            targetIdentity: targetIdentity
        ) { [noticeContinuation] in noticeContinuation.yield($0) }
        state = .ended
        // Closing ends the target session, so it waits until the commit or rollback is done.
        await connection.close()
        noticeContinuation.finish()
        return stop
    }

    // MARK: - Classes and lines

    // A unit the target ran before CONNECT_TCP (a logon trigger, the connection's startup commands) is already loaded,
    // and no CLASS_PREPARE announces it.
    private func adoptIfLoaded(_ unit: OracleDebugUnit) async {
        guard let id = await loadedClass(unit) else { return }
        await prepared(typeID: id, signature: unit.jdwpSignature)
    }

    private func prepared(typeID: UInt64, signature: String) async {
        guard !preparedClasses.contains(typeID) else { return }
        preparedClasses.insert(typeID)
        let unit = OracleDebugUnit(jdwpSignature: signature)
        classes[typeID] = ClassInfo(id: typeID, unit: unit)
        guard let unit else { return }
        classIDs[unit] = typeID
        if unit == entryPoint.entry.unit {
            await installEntryBreakpoints(classID: typeID)
        }
        for key in pending where key.unit == unit {
            pending.remove(key)
            if let placedLine = try? await place(key.line, in: unit, classID: typeID) {
                if placedLine != key.line {
                    holds.move(key.line, to: placedLine, in: unit)
                    noticeContinuation.yield(.breakpointMoved(unit: unit, from: key.line, to: placedLine))
                }
            } else {
                holds.drop(key.line, in: unit)
                noticeContinuation.yield(.breakpointHasNoCode(unit: unit, line: key.line))
            }
        }
    }

    // Every overload with the entry point's name: the anonymous block calls only the one asked for, so the first hit
    // is it. The first code index is the subprogram's header line, where DBMS_DEBUG stops on entry as well.
    private func installEntryBreakpoints(classID: UInt64) async {
        guard let methods = try? await methods(of: classID) else { return }
        for method in methods where method.name == entryPoint.entry.subprogram {
            guard let table = try? await lineTable(classID: classID, methodID: method.id),
                  let first = table.entries.first else { continue }
            let location = OracleJDWPLocation(classID: classID, methodID: method.id, index: first.index)
            if let request = try? await setBreakpointRequest(at: location) {
                entryRequests.insert(request)
            }
        }
    }

    private func clearEntryRequests() async {
        let requests = entryRequests.subtracting(placed.values)
        entryRequests.removeAll()
        for request in requests {
            _ = try? await connection.send(
                OracleJDWPCommand.eventRequest,
                OracleJDWPCommand.clear,
                OracleJDWPRequest.clear(kind: .breakpoint, requestID: request, sizes: sizes)
            )
        }
    }

    private func methods(of classID: UInt64) async throws -> [OracleJDWPMethod] {
        if let methods = classes[classID]?.methods { return methods }
        let reply = try await connection.send(
            OracleJDWPCommand.referenceType,
            OracleJDWPCommand.methods,
            idData(classID, .referenceType)
        )
        let methods = try OracleJDWPMethod.decodeList(reply, sizes: sizes)
        classes[classID]?.methods = methods
        return methods
    }

    private func lineTable(classID: UInt64, methodID: UInt64) async throws -> OracleJDWPLineTable {
        if let table = classes[classID]?.lineTables[methodID] { return table }
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.id(classID, .referenceType)
        writer.id(methodID, .method)
        let reply = try await connection.send(OracleJDWPCommand.method, OracleJDWPCommand.lineTable, writer.data)
        let table = try OracleJDWPLineTable.decode(reply, sizes: sizes)
        classes[classID]?.lineTables[methodID] = table
        return table
    }

    private func idData(_ id: UInt64, _ kind: OracleJDWPIDKind) -> Data {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.id(id, kind)
        return writer.data
    }

    // Only a unit's own classes are read: asking for the line table of a local collection type's method ended the
    // target with ORA-00600 [kgamgub4_1] on 23.26 (measured).
    private func classInfo(_ classID: UInt64) async -> ClassInfo {
        if let info = classes[classID] { return info }
        var unit: OracleDebugUnit?
        if var reader = try? OracleJDWPReader(
            await connection.send(OracleJDWPCommand.referenceType, OracleJDWPCommand.signature, idData(classID, .referenceType)),
            sizes: sizes
        ), let signature = try? reader.string() {
            unit = OracleDebugUnit(jdwpSignature: signature)
        }
        let info = ClassInfo(id: classID, unit: unit)
        classes[classID] = info
        if let unit { classIDs[unit] = classID }
        return info
    }

    private func resolve(_ location: OracleJDWPLocation) async -> OracleDebugLocation? {
        guard let unit = await classInfo(location.classID).unit,
              let table = try? await lineTable(classID: location.classID, methodID: location.methodID),
              let line = table.line(at: location.index) else { return nil }
        return OracleDebugLocation(unit: unit, line: line)
    }

    private func place(_ line: Int, in unit: OracleDebugUnit, classID: UInt64) async throws -> Int? {
        var best: (location: OracleJDWPLocation, line: Int, covers: Bool)?
        for method in try await methods(of: classID) {
            guard let table = try? await lineTable(classID: classID, methodID: method.id),
                  let candidate = table.location(atOrAfter: line) else { continue }
            let covers = table.covers(line: line)
            let location = OracleJDWPLocation(classID: classID, methodID: method.id, index: candidate.index)
            if let current = best {
                if current.covers && !covers { continue }
                if covers == current.covers && candidate.line >= current.line { continue }
            }
            best = (location, candidate.line, covers)
        }
        guard let best else { return nil }
        let key = BreakpointKey(unit: unit, line: best.line)
        if placed[key] == nil {
            placed[key] = try await setBreakpointRequest(at: best.location)
        }
        return best.line
    }

    private func setBreakpointRequest(at location: OracleJDWPLocation) async throws -> Int32 {
        var reader = OracleJDWPReader(
            try await connection.send(
                OracleJDWPCommand.eventRequest,
                OracleJDWPCommand.set,
                OracleJDWPRequest.breakpoint(at: location, sizes: sizes)
            ),
            sizes: sizes
        )
        return try reader.i32()
    }

    // MARK: - Breakpoints

    public func setBreakpoint(in unit: OracleDebugUnit, line: Int) async throws -> Int? {
        try await setBreakpoint(in: unit, line: line, atStart: false)
    }

    private func setBreakpoint(in unit: OracleDebugUnit, line: Int, atStart: Bool) async throws -> Int? {
        guard state != .ended else { throw OracleDebugError.ended }
        guard let landed = try await guarded({ try await placeBreakpoint(in: unit, line: line) }) else { return nil }
        holds.hold(landed, in: unit, by: atStart ? line : landed)
        return landed
    }

    private func placeBreakpoint(in unit: OracleDebugUnit, line: Int) async throws -> Int? {
        if classIDs[unit] == nil {
            await adoptIfLoaded(unit)
        }
        if let classID = classIDs[unit] {
            return try await place(line, in: unit, classID: classID)
        }
        // Not loaded yet: DBMS_DEBUG's line map answers for it, and the line table places it once the class loads.
        guard let lines = try await OracleDebugSupport.executableLines(of: unit, on: helper),
              let resolved = lines.first(where: { $0 >= line }) else { return nil }
        pending.insert(BreakpointKey(unit: unit, line: resolved))
        try await requestPrepare(of: unit)
        return resolved
    }

    public func removeBreakpoint(in unit: OracleDebugUnit, line: Int) async throws {
        guard let landed = holds.release(line, in: unit) else { return }
        let key = BreakpointKey(unit: unit, line: landed)
        pending.remove(key)
        guard let request = placed.removeValue(forKey: key) else { return }
        do {
            try await guarded {
                _ = try await connection.send(
                    OracleJDWPCommand.eventRequest,
                    OracleJDWPCommand.clear,
                    OracleJDWPRequest.clear(kind: .breakpoint, requestID: request, sizes: sizes)
                )
            }
        } catch {
            // Still set in the VM, so removing it again has to find it.
            holds.hold(landed, in: unit, by: line)
            placed[key] = request
            throw error
        }
    }

    // MARK: - Inspection

    public func source(of unit: OracleDebugUnit) async throws -> String {
        try await guarded { try await OracleDebugSupport.source(of: unit, on: helper) }
    }

    public func stack() async throws -> [OracleDebugFrame] {
        guard state == .paused else { throw OracleDebugError.notPaused }
        try await guarded { try await loadFrames() }
        return frames.enumerated().map { level, frame in
            OracleDebugFrame(level: level, location: frame.resolved, subprogram: frame.method?.name)
        }
    }

    private func loadFrames() async throws {
        guard frames.isEmpty else { return }
        var reader = try await send(OracleJDWPCommand.threadReference, OracleJDWPCommand.frames) { writer in
            writer.id(thread, .object)
            writer.i32(0)
            writer.i32(-1)
        }
        let count = try reader.count(minimumSize: sizes.frame + 1 + sizes.referenceType + sizes.method + 8)
        var loaded: [FrameInfo] = []
        for _ in 0..<count {
            let id = try reader.id(.frame)
            let location = try reader.location()
            // The anonymous blocks below the entry point have no source and no readable slots (error 35).
            guard let resolved = await resolve(location) else { continue }
            let method = classes[location.classID]?.methods?.first { $0.id == location.methodID }
            loaded.append(FrameInfo(id: id, location: location, resolved: resolved, method: method))
        }
        frames = loaded
    }

    public func variables(inFrame level: Int) async throws -> [OracleDebugVariable] {
        guard state == .paused else { throw OracleDebugError.notPaused }
        return try await guarded { try await readVariables(inFrame: level) }
    }

    private func readVariables(inFrame level: Int) async throws -> [OracleDebugVariable] {
        try await loadFrames()
        guard frames.indices.contains(level) else { return [] }
        let frame = frames[level]
        let table = try await variableTable(classID: frame.location.classID, methodID: frame.location.methodID)
        let visible = table.filter { $0.isUserVariable && $0.isVisible(at: frame.location.index) }
        let values = try await Self.readSlots(visible) { variables in
            try await slotValues(variables, frame: frame)
        }
        var result: [OracleDebugVariable] = []
        for (variable, value) in zip(visible, values) {
            var described = OracleDebugValue.unavailable
            if let value {
                described = await describe(value)
            }
            result.append(OracleDebugVariable(
                name: variable.name,
                kind: variable.isArgument ? .argument : .local,
                typeName: OracleDebugUnit.typeName(fromJDWPSignature: variable.signature),
                value: described,
                isConstant: false
            ))
        }
        return result + (await packageVariables(of: frame.resolved.unit))
    }

    // One unreadable slot (INVALID_SLOT 35, say) fails the whole request; then each is read alone and the unreadable
    // one is left out.
    static func readSlots<Variable: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ variables: [Variable],
        read: ([Variable]) async throws -> [OracleJDWPValue?]
    ) async throws -> [OracleJDWPValue?] {
        do {
            return try await read(variables)
        } catch OracleJDWPError.reply {
            var values: [OracleJDWPValue?] = []
            for variable in variables {
                values.append((try? await read([variable]))?.first ?? nil)
            }
            return values
        }
    }

    private func slotValues(_ variables: [OracleJDWPVariable], frame: FrameInfo) async throws -> [OracleJDWPValue?] {
        guard !variables.isEmpty else { return [] }
        var reader = try await send(OracleJDWPCommand.stackFrame, OracleJDWPCommand.frameValues) { writer in
            writer.id(thread, .object)
            writer.id(frame.id, .frame)
            writer.i32(Int32(variables.count))
            for variable in variables {
                writer.i32(Int32(variable.slot))
                writer.u8(variable.signature.utf8.first ?? OracleJDWPValue.objectTag)
            }
        }
        let count = try reader.count(minimumSize: 1)
        var values: [OracleJDWPValue?] = []
        for _ in 0..<min(count, variables.count) {
            values.append(try reader.taggedValue())
        }
        return values + Array(repeating: nil, count: variables.count - values.count)
    }

    private func variableTable(classID: UInt64, methodID: UInt64) async throws -> [OracleJDWPVariable] {
        let key = MethodKey(classID: classID, methodID: methodID)
        if let table = variableTables[key] { return table }
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.id(classID, .referenceType)
        writer.id(methodID, .method)
        let reply = try await connection.send(OracleJDWPCommand.method, OracleJDWPCommand.variableTable, writer.data)
        let table = try OracleJDWPVariable.decodeTable(reply, sizes: sizes)
        variableTables[key] = table
        return table
    }

    // The body's and the specification's package-level variables are their classes' static fields.
    private func packageVariables(of unit: OracleDebugUnit) async -> [OracleDebugVariable] {
        guard unit.kind == .packageBody || unit.kind == .package else { return [] }
        var result: [OracleDebugVariable] = []
        for kind in [OracleDebugUnitKind.packageBody, .package] {
            let owner = OracleDebugUnit(owner: unit.owner, name: unit.name, kind: kind)
            guard let classID = await loadedClass(owner),
                  let fields = try? await fields(of: classID) else { continue }
            let statics = fields.filter { $0.isStatic && !$0.name.hasPrefix("_") }
            guard !statics.isEmpty, var reader = try? await send(OracleJDWPCommand.referenceType, OracleJDWPCommand.staticValues, { writer in
                writer.id(classID, .referenceType)
                writer.i32(Int32(statics.count))
                for field in statics { writer.id(field.id, .field) }
            }), let count = try? reader.count(minimumSize: 1) else { continue }
            for field in statics.prefix(count) {
                guard let value = try? reader.taggedValue() else { break }
                result.append(OracleDebugVariable(
                    name: field.name,
                    kind: .package,
                    typeName: OracleDebugUnit.typeName(fromJDWPSignature: field.signature),
                    value: await describe(value),
                    isConstant: false
                ))
            }
        }
        return result
    }

    private func loadedClass(_ unit: OracleDebugUnit) async -> UInt64? {
        if let id = classIDs[unit] { return id }
        guard var reader = try? await send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.classesBySignature, { writer in
            writer.string(unit.jdwpSignature)
        }), let count = try? reader.count(minimumSize: 1 + sizes.referenceType + 4), count > 0 else { return nil }
        _ = try? reader.u8()
        guard let id = try? reader.id(.referenceType) else { return nil }
        classIDs[unit] = id
        if classes[id] == nil { classes[id] = ClassInfo(id: id, unit: unit) }
        return id
    }

    private func fields(of typeID: UInt64) async throws -> [OracleJDWPField] {
        if let fields = fieldCache[typeID] { return fields }
        let reply = try await connection.send(OracleJDWPCommand.referenceType, OracleJDWPCommand.fields, idData(typeID, .referenceType))
        let fields = try OracleJDWPField.decodeList(reply, sizes: sizes)
        fieldCache[typeID] = fields
        return fields
    }

    private func describe(_ value: OracleJDWPValue, depth: Int = 0) async -> OracleDebugValue {
        guard let objectID = value.objectID else { return .unavailable }
        guard objectID != 0 else { return .scalar(nil) }
        guard var typeReader = try? await send(OracleJDWPCommand.objectReference, OracleJDWPCommand.objectReferenceType, { writer in
            writer.id(objectID, .object)
        }), (try? typeReader.u8()) != nil, let typeID = try? typeReader.id(.referenceType),
              let fields = try? await fields(of: typeID) else { return .unavailable }
        switch OracleDebugValueShape(fields: fields) {
        case .scalar(let field):
            guard let values = try? await objectValues(objectID, fields: [field]), let text = values.first else {
                return .unavailable
            }
            return .scalar(await string(text))
        case .record(let members):
            guard depth == 0, let values = try? await objectValues(objectID, fields: members.map(\.id)) else {
                return .record([])
            }
            var described: [OracleDebugRecordMember] = []
            for (member, memberValue) in zip(members, values) {
                if case .scalar(let text) = await describe(memberValue, depth: depth + 1) {
                    described.append(OracleDebugRecordMember(name: member.name, value: text))
                }
            }
            return .record(described)
        case .collection(let field):
            guard let values = try? await objectValues(objectID, fields: [field]),
                  let arrayID = values.first?.objectID, arrayID != 0,
                  var reader = try? await send(OracleJDWPCommand.arrayReference, OracleJDWPCommand.arrayLength, { writer in
                      writer.id(arrayID, .object)
                  }), let length = try? reader.i32(), length >= 0 else { return .collection(count: nil) }
            return .collection(count: Int(length))
        case .opaque:
            return .unavailable
        }
    }

    private func objectValues(_ objectID: UInt64, fields: [UInt64]) async throws -> [OracleJDWPValue] {
        var reader = try await send(OracleJDWPCommand.objectReference, OracleJDWPCommand.objectValues) { writer in
            writer.id(objectID, .object)
            writer.i32(Int32(fields.count))
            for field in fields { writer.id(field, .field) }
        }
        let count = try reader.count(minimumSize: 1)
        var values: [OracleJDWPValue] = []
        for _ in 0..<count {
            values.append(try reader.taggedValue())
        }
        return values
    }

    private func string(_ value: OracleJDWPValue) async -> String? {
        guard let id = value.objectID, id != 0,
              var reader = try? await send(OracleJDWPCommand.stringReference, OracleJDWPCommand.stringValue, { writer in
                  writer.id(id, .object)
              }) else { return nil }
        return try? reader.string()
    }

    // MARK: - Stop

    // Closing the socket without Dispose ends the target session in any state: ORA-30687 within a second while it
    // was running a loop, and while paused (measured). The server rolls its transaction back with it.
    // Closing the socket first fails every reply still awaited, so a read or breakpoint call Stop overlaps throws at
    // once, and it ends the target: PL/SQL sees the close and ends with ORA-30687 within a second (measured).
    public func stop() async -> OracleDebugStopResult {
        if stopRequested {
            if !isStopped {
                await withCheckedContinuation { stopWaiters.append($0) }
            }
            return stopResult
        }
        stopRequested = true
        await connection.close()
        if let call {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: OracleDebugStopBudget.total - OracleDebugStopBudget.cleanup)
            // A call that never returns to PL/SQL (DBMS_SESSION.SLEEP, measured) does not see the close, so it is
            // killed from the helper session, as is one whose own connection failed under it.
            var ended = await OracleDebugSupport.endedOnServer(call, within: 1)
            if !ended {
                ended = await OracleDebugStopBudget.endRunningTarget(clock: clock, budget: clock.now.duration(to: deadline)) {
                    await OracleDebugSupport.kill(
                        targetIdentity,
                        from: helper,
                        within: OracleDebugStopBudget.seconds(clock.now.duration(to: deadline))
                    )
                } waitForEnd: { remaining in
                    await OracleDebugSupport.endedOnServer(call, within: OracleDebugStopBudget.seconds(remaining))
                }
            }
            if !ended {
                gaveUp = true
                target.cancelCurrentQuery()
            }
            stopResult = ended ? .ended : .unconfirmed(targetIdentity)
        } else {
            // Before the routine ran the target held no work; the closed socket ends its session.
            _ = await OracleDebugSupport.value(of: connectCall, within: 1)
            stopResult = .ended
        }
        state = .ended
        post(.connectionClosed)
        pump?.cancel()
        noticeContinuation.finish()
        isStopped = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return stopResult
    }
}
