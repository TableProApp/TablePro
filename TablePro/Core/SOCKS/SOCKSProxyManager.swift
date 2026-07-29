//
//  SOCKSProxyManager.swift
//  TablePro
//

import Foundation
import Network
import os

enum SOCKSProxyError: Error, LocalizedError, Equatable {
    case invalidConfiguration
    case listenerFailed(String)
    case connectTimedOut(proxyHost: String, proxyPort: Int)
    case connectFailed(proxyHost: String, proxyPort: Int, underlying: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return String(localized: "The SOCKS proxy configuration is incomplete. Enter a proxy host and port.")
        case .listenerFailed(let reason):
            return String(format: String(localized: "Could not open a local port for the SOCKS proxy: %@"), reason)
        case .connectTimedOut(let proxyHost, let proxyPort):
            return String(
                format: String(localized: "Timed out connecting through the SOCKS proxy at %@:%@. Check that the proxy is reachable and the credentials are correct."),
                proxyHost, String(proxyPort)
            )
        case .connectFailed(let proxyHost, let proxyPort, let underlying):
            return String(
                format: String(localized: "Could not connect through the SOCKS proxy at %@:%@. %@"),
                proxyHost, String(proxyPort), underlying
            )
        }
    }
}

actor SOCKSProxyManager: TunnelManaging {
    static let shared = SOCKSProxyManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SOCKSProxyManager")
    private static let networkQueue = DispatchQueue(label: "com.TablePro.SOCKSProxyManager.network")

    private struct RelayPair {
        let inbound: NWConnection
        let outbound: NWConnection
    }

    private struct TunnelState {
        let listener: NWListener
        let localPort: Int
        var relays: [UUID: RelayPair] = [:]
    }

    private var tunnels: [UUID: TunnelState] = [:]
    private var appNapActivity: NSObjectProtocol?
    private let connectTimeout: TimeInterval

    init(connectTimeout: TimeInterval = 15) {
        self.connectTimeout = connectTimeout
    }

    func createTunnel(
        connectionId: UUID,
        config: SOCKSProxyConfiguration,
        password: String?,
        targetHost: String,
        targetPort: Int
    ) async throws -> Int {
        guard config.isValid, Self.nwPort(config.port) != nil, Self.nwPort(targetPort) != nil else {
            throw SOCKSProxyError.invalidConfiguration
        }

        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
        }

        let privacyContext = Self.makePrivacyContext(connectionId: connectionId, config: config, password: password)
        try await probeProxyPath(config: config, privacyContext: privacyContext, targetHost: targetHost, targetPort: targetPort)

        let listener = try makeListener()
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else {
                inbound.cancel()
                return
            }
            Task {
                await self.acceptClient(
                    inbound,
                    connectionId: connectionId,
                    config: config,
                    privacyContext: privacyContext,
                    targetHost: targetHost,
                    targetPort: targetPort
                )
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { await self?.handleListenerDeath(connectionId: connectionId, listener: listener, error: error) }
        }

        let localPort = try await Self.startListener(listener)
        tunnels[connectionId] = TunnelState(listener: listener, localPort: localPort)
        updateAppNapState()
        Self.logger.info("SOCKS proxy tunnel ready for \(connectionId.uuidString, privacy: .public) on 127.0.0.1:\(localPort)")
        return localPort
    }

    func closeTunnel(connectionId: UUID) async throws {
        guard let state = tunnels.removeValue(forKey: connectionId) else { return }
        updateAppNapState()
        state.listener.stateUpdateHandler = nil
        state.listener.cancel()
        for relay in state.relays.values {
            relay.inbound.cancel()
            relay.outbound.cancel()
        }
    }

    func closeAllTunnels() async {
        let connectionIds = Array(tunnels.keys)
        for connectionId in connectionIds {
            try? await closeTunnel(connectionId: connectionId)
        }
    }

    func hasTunnel(connectionId: UUID) -> Bool {
        tunnels[connectionId] != nil
    }

    func getLocalPort(connectionId: UUID) -> Int? {
        tunnels[connectionId]?.localPort
    }

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.preferNoProxies = true
        do {
            return try NWListener(using: parameters)
        } catch {
            throw SOCKSProxyError.listenerFailed(error.localizedDescription)
        }
    }

    private func probeProxyPath(
        config: SOCKSProxyConfiguration,
        privacyContext: NWParameters.PrivacyContext,
        targetHost: String,
        targetPort: Int
    ) async throws {
        let probe = Self.makeProxiedConnection(privacyContext: privacyContext, targetHost: targetHost, targetPort: targetPort)
        defer { probe.cancel() }
        try await Self.waitUntilReady(probe, timeout: connectTimeout, proxyHost: config.host, proxyPort: config.port)
    }

    private func acceptClient(
        _ inbound: NWConnection,
        connectionId: UUID,
        config: SOCKSProxyConfiguration,
        privacyContext: NWParameters.PrivacyContext,
        targetHost: String,
        targetPort: Int
    ) {
        guard tunnels[connectionId] != nil else {
            inbound.cancel()
            return
        }

        let relayId = UUID()
        let outbound = Self.makeProxiedConnection(privacyContext: privacyContext, targetHost: targetHost, targetPort: targetPort)
        tunnels[connectionId]?.relays[relayId] = RelayPair(inbound: inbound, outbound: outbound)

        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.removeRelay(connectionId: connectionId, relayId: relayId) }
            default:
                break
            }
        }
        inbound.start(queue: Self.networkQueue)

        Task { [connectTimeout] in
            do {
                try await Self.waitUntilReady(outbound, timeout: connectTimeout, proxyHost: config.host, proxyPort: config.port)
                outbound.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled:
                        Task { await self?.removeRelay(connectionId: connectionId, relayId: relayId) }
                    default:
                        break
                    }
                }
                let finishedDirections = OSAllocatedUnfairLock(initialState: 0)
                let onDirectionFinished: @Sendable () -> Void = { [weak self] in
                    let bothFinished = finishedDirections.withLock { count -> Bool in
                        count += 1
                        return count == 2
                    }
                    guard bothFinished else { return }
                    Task { await self?.removeRelay(connectionId: connectionId, relayId: relayId) }
                }
                Self.pump(inbound, into: outbound, onFinished: onDirectionFinished)
                Self.pump(outbound, into: inbound, onFinished: onDirectionFinished)
            } catch {
                Self.logger.warning("SOCKS relay setup failed for \(connectionId.uuidString, privacy: .public): \(error.localizedDescription)")
                await self.removeRelay(connectionId: connectionId, relayId: relayId)
            }
        }
    }

    private func removeRelay(connectionId: UUID, relayId: UUID) {
        guard let relay = tunnels[connectionId]?.relays.removeValue(forKey: relayId) else { return }
        relay.inbound.cancel()
        relay.outbound.cancel()
    }

    private func handleListenerDeath(connectionId: UUID, listener: NWListener, error: NWError) async {
        guard let state = tunnels[connectionId], state.listener === listener else { return }
        tunnels.removeValue(forKey: connectionId)
        updateAppNapState()
        for relay in state.relays.values {
            relay.inbound.cancel()
            relay.outbound.cancel()
        }
        Self.logger.warning("SOCKS proxy listener died for \(connectionId.uuidString, privacy: .public): \(error.localizedDescription)")
        await DatabaseManager.shared.handleSOCKSProxyTunnelDied(connectionId: connectionId)
    }

    private func updateAppNapState() {
        if !tunnels.isEmpty, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "SOCKS proxy tunnel requires timely execution"
            )
        } else if tunnels.isEmpty, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    private static func nwPort(_ port: Int) -> NWEndpoint.Port? {
        UInt16(exactly: port).flatMap { $0 > 0 ? NWEndpoint.Port(rawValue: $0) : nil }
    }

    private static func makePrivacyContext(
        connectionId: UUID,
        config: SOCKSProxyConfiguration,
        password: String?
    ) -> NWParameters.PrivacyContext {
        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: nwPort(config.port) ?? 1_080
        )
        var proxy = ProxyConfiguration(socksv5Proxy: proxyEndpoint)
        if !config.username.isEmpty, let password, !password.isEmpty {
            proxy.applyCredential(username: config.username, password: password)
        }
        let context = NWParameters.PrivacyContext(description: "TablePro-SOCKS-\(connectionId.uuidString)")
        context.proxyConfigurations = [proxy]
        return context
    }

    private static func makeProxiedConnection(
        privacyContext: NWParameters.PrivacyContext,
        targetHost: String,
        targetPort: Int
    ) -> NWConnection {
        let parameters = NWParameters.tcp
        parameters.setPrivacyContext(privacyContext)
        return NWConnection(
            host: NWEndpoint.Host(targetHost),
            port: nwPort(targetPort) ?? 1_080,
            using: parameters
        )
    }

    private static func startListener(_ listener: NWListener) async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let existingHandler = listener.stateUpdateHandler
                let finish: (Result<Int, Error>) -> Void = { result in
                    let shouldResume = resumed.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    guard shouldResume else { return }
                    listener.stateUpdateHandler = existingHandler
                    continuation.resume(with: result)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            finish(.success(Int(port.rawValue)))
                        } else {
                            listener.cancel()
                            finish(.failure(SOCKSProxyError.listenerFailed("no port assigned")))
                        }
                    case .failed(let error):
                        listener.cancel()
                        finish(.failure(SOCKSProxyError.listenerFailed(error.localizedDescription)))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                listener.start(queue: networkQueue)
            }
        } onCancel: {
            listener.cancel()
        }
    }

    private static func waitUntilReady(
        _ connection: NWConnection,
        timeout: TimeInterval,
        proxyHost: String,
        proxyPort: Int
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let finish: (Result<Void, Error>) -> Void = { result in
                    let shouldResume = resumed.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    guard shouldResume else { return }
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        finish(.success(()))
                    case .failed(let error):
                        connection.cancel()
                        finish(.failure(SOCKSProxyError.connectFailed(
                            proxyHost: proxyHost,
                            proxyPort: proxyPort,
                            underlying: error.localizedDescription
                        )))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                networkQueue.asyncAfter(deadline: .now() + timeout) {
                    let timedOut = resumed.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    guard timedOut else { return }
                    connection.cancel()
                    continuation.resume(throwing: SOCKSProxyError.connectTimedOut(proxyHost: proxyHost, proxyPort: proxyPort))
                }
                connection.start(queue: networkQueue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func pump(
        _ source: NWConnection,
        into destination: NWConnection,
        onFinished: @escaping @Sendable () -> Void
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    guard sendError == nil else {
                        source.cancel()
                        destination.cancel()
                        onFinished()
                        return
                    }
                    if isComplete {
                        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                        onFinished()
                        return
                    }
                    pump(source, into: destination, onFinished: onFinished)
                })
                return
            }
            if isComplete {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                onFinished()
                return
            }
            if error != nil {
                source.cancel()
                destination.cancel()
                onFinished()
                return
            }
            pump(source, into: destination, onFinished: onFinished)
        }
    }
}
