import Foundation
import os

final class HanaConnection: HanaSession, @unchecked Sendable {
    private enum Target: Sendable {
        case connecting(UInt64)
        case connected
    }

    private struct Admission: Sendable {
        let ticket: HanaOperationTicket
        let epoch: UInt64
    }

    private struct State {
        var session: UInt64 = 0
        var isAdopted = false
        var epoch: UInt64 = 0
        var lastOperation: UInt64 = 0
        var queryTimeoutSeconds = 0
        var hasLostConnection = false
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "HanaConnection")

    private let bridge: any HanaNativeBridge
    private let queue: any HanaOperationQueue
    private let stateLock = NSLock()
    private var state = State()

    init(
        bridge: any HanaNativeBridge = HanaHelperBridge(),
        queue: any HanaOperationQueue = DispatchQueue(label: "com.TablePro.hana.connection", qos: .userInitiated)
    ) {
        self.bridge = bridge
        self.queue = queue
    }

    deinit {
        closeNative(state.session)
    }

    var hasLostConnection: Bool {
        stateLock.withLock { state.hasLostConnection }
    }

    func connect(_ configuration: HanaConnectConfiguration) async throws -> HanaConnectResult {
        let configurationJSON = try JSONEncoder().encode(configuration)
        let attempt = beginAttempt()
        let session = try await open(configurationJSON)
        guard claim(session, attempt: attempt) else {
            closeNative(session)
            throw HanaBridgeFailure.closed
        }
        let result: HanaConnectResult
        do {
            result = try await perform(.connecting(session), cancellation: HanaOperationSlot()) { bridge, ticket in
                try Self.decode(HanaConnectResult.self, from: bridge.connect(ticket))
            }
        } catch {
            abandon(session)
            throw error
        }
        guard adopt(session, attempt: attempt) else {
            abandon(session)
            throw HanaBridgeFailure.closed
        }
        Self.logger.debug("SAP HANA session connected as connection \(result.connectionId)")
        return result
    }

    func disconnect() {
        let (session, _) = retireSession()
        closeNative(session)
    }

    func ping() async throws {
        try await perform(.connected, cancellation: HanaOperationSlot()) { bridge, ticket in
            try bridge.ping(ticket)
        }
    }

    func execute(
        sql: String,
        parameters: [HanaBridgeCell]?,
        rowCap: Int,
        cancellation: HanaOperationSlot
    ) async throws -> HanaResultEnvelope {
        let request = HanaExecuteRequest(
            sql: sql,
            parameters: parameters,
            rowCap: rowCap,
            timeoutSeconds: queryTimeoutSeconds
        )
        let requestJSON = try JSONEncoder().encode(request)
        return try await statement(cancellation) { bridge, ticket in
            try bridge.execute(ticket, request: requestJSON)
        }
    }

    func explain(sql: String, cancellation: HanaOperationSlot) async throws -> HanaResultEnvelope {
        let requestJSON = try JSONEncoder().encode(HanaExplainRequest(sql: sql, timeoutSeconds: queryTimeoutSeconds))
        return try await statement(cancellation) { bridge, ticket in
            try bridge.explain(ticket, request: requestJSON)
        }
    }

    func cancel(_ cancellation: HanaOperationSlot) {
        guard let ticket = cancellation.cancel() else { return }
        bridge.cancel(ticket)
    }

    func applyQueryTimeout(seconds: Int) {
        stateLock.withLock { state.queryTimeoutSeconds = max(0, seconds) }
    }

    private var queryTimeoutSeconds: Int {
        stateLock.withLock { state.queryTimeoutSeconds }
    }

    private func open(_ configurationJSON: Data) async throws -> UInt64 {
        let interruption = HanaOpenInterruption()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.submit {
                    continuation.resume(with: Result {
                        try self.bridge.open(configuration: configurationJSON, interruption: interruption)
                    })
                }
            }
        } onCancel: {
            interruption.interrupt()
        }
    }

    private func beginAttempt() -> UInt64 {
        let (previous, attempt) = retireSession()
        closeNative(previous)
        return attempt
    }

    private func retireSession() -> (session: UInt64, epoch: UInt64) {
        stateLock.withLock {
            let current = state.session
            state.session = 0
            state.isAdopted = false
            state.hasLostConnection = false
            state.epoch &+= 1
            return (current, state.epoch)
        }
    }

    private func claim(_ session: UInt64, attempt: UInt64) -> Bool {
        stateLock.withLock {
            guard state.epoch == attempt, state.session == 0 else { return false }
            state.session = session
            state.isAdopted = false
            return true
        }
    }

    private func adopt(_ session: UInt64, attempt: UInt64) -> Bool {
        stateLock.withLock {
            guard state.epoch == attempt, state.session == session else { return false }
            state.isAdopted = true
            return true
        }
    }

    private func abandon(_ session: UInt64) {
        stateLock.withLock {
            guard state.session == session else { return }
            state.session = 0
            state.isAdopted = false
        }
        closeNative(session)
    }

    private func closeNative(_ session: UInt64) {
        guard session != 0 else { return }
        bridge.close(session: session)
    }

    private func statement(
        _ cancellation: HanaOperationSlot,
        _ call: @escaping @Sendable (any HanaNativeBridge, HanaOperationTicket) throws -> Data
    ) async throws -> HanaResultEnvelope {
        try await perform(.connected, cancellation: cancellation) { bridge, ticket in
            let envelope = try Self.decode(HanaResultEnvelope.self, from: call(bridge, ticket))
            if envelope.sessionLost {
                Self.logger.error("SAP HANA session was lost after its statement completed")
                self.markLost(ticket.session)
            }
            return envelope
        }
    }

    private func perform<T: Sendable>(
        _ target: Target,
        cancellation slot: HanaOperationSlot,
        _ call: @escaping @Sendable (any HanaNativeBridge, HanaOperationTicket) throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                enqueue(target, slot: slot, continuation: continuation, call: call)
            }
        } onCancel: {
            cancel(slot)
        }
    }

    private func enqueue<T: Sendable>(
        _ target: Target,
        slot: HanaOperationSlot,
        continuation: CheckedContinuation<T, any Error>,
        call: @escaping @Sendable (any HanaNativeBridge, HanaOperationTicket) throws -> T
    ) {
        let refusal = stateLock.withLock { () -> (any Error)? in
            guard let session = resolve(target) else { return HanaBridgeFailure.closed }
            state.lastOperation &+= 1
            let admission = Admission(
                ticket: HanaOperationTicket(session: session, operation: state.lastOperation),
                epoch: state.epoch
            )
            guard slot.assign(admission.ticket) else { return CancellationError() }
            queue.submit {
                self.run(admission, target: target, slot: slot, continuation: continuation, call: call)
            }
            return nil
        }
        guard let refusal else { return }
        continuation.resume(throwing: refusal)
    }

    private func run<T: Sendable>(
        _ admission: Admission,
        target: Target,
        slot: HanaOperationSlot,
        continuation: CheckedContinuation<T, any Error>,
        call: @Sendable (any HanaNativeBridge, HanaOperationTicket) throws -> T
    ) {
        if let refusal = start(admission, target: target, slot: slot) {
            continuation.resume(throwing: refusal)
            return
        }
        let outcome = Result { try call(bridge, admission.ticket) }
        if case .failure(let error) = outcome, (error as? HanaBridgeFailure)?.kind == .connectionLost {
            markLost(admission.ticket.session)
        }
        continuation.resume(with: outcome)
    }

    private func start(_ admission: Admission, target: Target, slot: HanaOperationSlot) -> (any Error)? {
        stateLock.withLock { () -> (any Error)? in
            guard state.epoch == admission.epoch, resolve(target) == admission.ticket.session else {
                Self.logger.debug("SAP HANA operation \(admission.ticket.operation) dropped: its session was closed")
                return HanaBridgeFailure.closed
            }
            guard !slot.isCancelled else { return CancellationError() }
            return nil
        }
    }

    private func markLost(_ session: UInt64) {
        stateLock.withLock {
            guard state.session == session else { return }
            state.hasLostConnection = true
        }
    }

    private func resolve(_ target: Target) -> UInt64? {
        switch target {
        case .connecting(let session):
            guard state.session == session, !state.isAdopted else { return nil }
            return session
        case .connected:
            guard state.session != 0, state.isAdopted else { return nil }
            return state.session
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("SAP HANA bridge returned unreadable JSON: \(error.localizedDescription, privacy: .private)")
            throw HanaError.unreadableResult
        }
    }
}
