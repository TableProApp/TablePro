import Foundation
import Network
import os
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "OracleJDWPListener")

public enum OracleJDWPListenerError: Error, Sendable, Equatable {
    case noFreePort(ClosedRange<UInt16>)
    // `rejected` lists the addresses that connected and were not the database server's.
    case timedOut(rejected: [String])
    case cancelled
}

// Waits for the database to connect back. It binds the given local addresses on one random port of the range,
// accepts only peers from the database server's addresses, gives each two seconds to send the JDWP handshake, and
// keeps the first that does: every other connection closes and the listener stops.
public final class OracleJDWPListener: @unchecked Sendable {
    public let port: UInt16
    private let listeners: [NWListener]
    private let queue: DispatchQueue
    private let allowedPeers: Set<String>?
    private let state = OSAllocatedUnfairLock(initialState: State())

    // NWConnection is Sendable only from macOS 14; it is thread-safe on every release this runs on.
    private struct Peer: @unchecked Sendable {
        let connection: NWConnection
    }

    private struct State {
        var peers: [ObjectIdentifier: Peer] = [:]
        var rejected: [String] = []
        var result: Result<OracleJDWPConnection, Error>?
        var waiter: CheckedContinuation<OracleJDWPConnection, Error>?
        var isFinished = false
    }

    static let handshakeSeconds: Double = 2
    static let portAttempts = 64

    private init(port: UInt16, listeners: [NWListener], queue: DispatchQueue, allowedPeers: Set<String>?) {
        self.port = port
        self.listeners = listeners
        self.queue = queue
        self.allowedPeers = allowedPeers
    }

    // `allowedPeers` nil accepts any address; `bindAddresses` nil listens on every interface.
    public static func open(
        ports: ClosedRange<UInt16>,
        bindAddresses: [String]?,
        allowedPeers: Set<String>?
    ) async throws -> OracleJDWPListener {
        for port in ports.shuffled().prefix(portAttempts) {
            if let listener = await bind(port: port, addresses: bindAddresses, allowedPeers: allowedPeers) {
                return listener
            }
        }
        throw OracleJDWPListenerError.noFreePort(ports)
    }

    private static func bind(port: UInt16, addresses: [String]?, allowedPeers: Set<String>?) async -> OracleJDWPListener? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        var made: [NWListener] = []
        for address in addresses ?? [] {
            let parameters = NWParameters.tcp
            // The required local endpoint carries the port; naming it again in `on:` fails the listener.
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: endpointPort)
            guard let listener = try? NWListener(using: parameters) else { return nil }
            made.append(listener)
        }
        if addresses == nil {
            guard let listener = try? NWListener(using: .tcp, on: endpointPort) else { return nil }
            made.append(listener)
        }
        guard !made.isEmpty else { return nil }
        let queue = DispatchQueue(label: "com.TablePro.OracleJDWPListener.\(port)")
        let instance = OracleJDWPListener(port: port, listeners: made, queue: queue, allowedPeers: allowedPeers)
        for listener in made {
            listener.newConnectionHandler = { [weak instance] peer in
                guard let instance else {
                    peer.cancel()
                    return
                }
                instance.arrived(peer)
            }
        }
        for listener in made {
            guard await start(listener, on: queue) else {
                for other in made {
                    other.cancel()
                }
                return nil
            }
        }
        return instance
    }

    private static func start(_ listener: NWListener, on queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { (result: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { result.resume(returning: value) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(true)
                case .failed, .cancelled: resume(false)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public var rejectedPeers: [String] {
        state.withLock { $0.rejected }
    }

    private func arrived(_ peer: NWConnection) {
        let address = Self.address(of: peer.endpoint)
        let admitted = state.withLock { current -> Bool in
            guard !current.isFinished else { return false }
            if let allowedPeers, !allowedPeers.contains(address ?? "") {
                current.rejected.append(address ?? String(describing: peer.endpoint))
                return false
            }
            current.peers[ObjectIdentifier(peer)] = Peer(connection: peer)
            return true
        }
        guard admitted else {
            logger.notice("Closed a debugger connection from an address that is not the database server's")
            peer.cancel()
            return
        }
        Task { await self.handshake(peer) }
    }

    private func handshake(_ peer: NWConnection) async {
        let ready = (try? await withOracleTimeout(seconds: Self.handshakeSeconds, onTimeout: { peer.cancel() }) {
            await self.start(peer)
        }) ?? false
        guard ready else {
            drop(peer)
            return
        }
        let connection = OracleJDWPConnection(transport: OracleJDWPNetworkTransport(connection: peer))
        do {
            try await withOracleTimeout(seconds: Self.handshakeSeconds, onTimeout: { peer.cancel() }) {
                try await connection.handshake()
            }
        } catch {
            await connection.close()
            drop(peer)
            return
        }
        await claim(connection, peer: peer)
    }

    private func start(_ peer: NWConnection) async -> Bool {
        await withCheckedContinuation { (result: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { result.resume(returning: value) }
            }
            peer.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(true)
                case .failed, .cancelled: resume(false)
                default: break
                }
            }
            peer.start(queue: queue)
        }
    }

    private func drop(_ peer: NWConnection) {
        state.withLock { _ = $0.peers.removeValue(forKey: ObjectIdentifier(peer)) }
        peer.cancel()
    }

    private func claim(_ connection: OracleJDWPConnection, peer: NWConnection) async {
        let claimed = state.withLock { current -> (others: [Peer], waiter: CheckedContinuation<OracleJDWPConnection, Error>?)? in
            guard !current.isFinished else { return nil }
            current.isFinished = true
            current.peers.removeValue(forKey: ObjectIdentifier(peer))
            let others = Array(current.peers.values)
            current.peers.removeAll()
            let waiter = current.waiter
            current.waiter = nil
            if waiter == nil { current.result = .success(connection) }
            return (others, waiter)
        }
        guard let claimed else {
            await connection.close()
            return
        }
        cancelListeners()
        for other in claimed.others {
            other.connection.cancel()
        }
        claimed.waiter?.resume(returning: connection)
    }

    private func finish(with error: Error) {
        let ended = state.withLock { current -> (others: [Peer], waiter: CheckedContinuation<OracleJDWPConnection, Error>?)? in
            guard !current.isFinished else { return nil }
            current.isFinished = true
            let others = Array(current.peers.values)
            current.peers.removeAll()
            let waiter = current.waiter
            current.waiter = nil
            if waiter == nil { current.result = .failure(error) }
            return (others, waiter)
        }
        cancelListeners()
        guard let ended else { return }
        for other in ended.others {
            other.connection.cancel()
        }
        ended.waiter?.resume(throwing: error)
    }

    public func accept(timeout: Duration) async throws -> OracleJDWPConnection {
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil, let self else { return }
            finish(with: OracleJDWPListenerError.timedOut(rejected: rejectedPeers))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OracleJDWPConnection, Error>) in
                let ready = state.withLock { current -> Result<OracleJDWPConnection, Error>? in
                    if let result = current.result {
                        current.result = nil
                        return result
                    }
                    if current.isFinished { return .failure(OracleJDWPListenerError.cancelled) }
                    current.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            finish(with: CancellationError())
        }
    }

    public func cancel() {
        finish(with: OracleJDWPListenerError.cancelled)
    }

    private func cancelListeners() {
        for listener in listeners {
            listener.cancel()
        }
    }

    static func address(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return OracleDebugNetwork.normalized("\(address)")
        case .ipv6(let address): return OracleDebugNetwork.normalized("\(address)")
        case .name(let name, _): return OracleDebugNetwork.normalized(name)
        @unknown default: return nil
        }
    }
}
