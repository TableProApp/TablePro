import Foundation
import os

internal enum MCPServerState: Sendable, Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)
}

@MainActor @Observable
internal final class MCPServerManager {
    internal struct SessionSnapshot: Sendable, Identifiable {
        internal let id: String
        internal let clientName: String
        internal let clientVersion: String?
        internal let connectedSince: Date
        internal let lastActivityAt: Date
        internal let tokenName: String?
        internal let remoteAddress: String?
    }

    private struct BridgeCredential {
        let tokenId: UUID
        let plaintext: String
        let expiresAt: Date
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPServerManager")
    private static let bridgeTokenLifetime: TimeInterval = 60 * 60
    private static let bridgeTokenRenewalLead: TimeInterval = 15 * 60
    private static let clientRefreshInterval: Duration = .seconds(5)

    internal static let shared = MCPServerManager()

    internal private(set) var state: MCPServerState = .stopped
    internal private(set) var connectedClients: [SessionSnapshot] = []
    internal private(set) var tokenStore: MCPTokenStore?

    private let lifecycle = MCPServerLifecycleQueue()
    private let handshake: MCPHandshakeFile

    private var composition: MCPServerComposition?
    private var bridgeCredential: BridgeCredential?
    private var instanceId = ""
    private var generation = 0
    private var revocationObserverId: UUID?
    private var dispatchTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var clientRefreshTask: Task<Void, Never>?
    private var tokenRenewalTask: Task<Void, Never>?

    internal var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    internal var listeningPort: Int? {
        if case .running(let port) = state { return Int(port) }
        return nil
    }

    private init(handshake: MCPHandshakeFile? = nil) {
        self.handshake = handshake
            ?? MCPHandshakeFile(directory: AppStorageEnvironment.shared.supportDirectory)
    }

    internal func start(port: UInt16) async {
        await lifecycle.run { [weak self] in
            await self?.performStart(port: port)
        }
    }

    internal func stop() async {
        await lifecycle.run { [weak self] in
            await self?.performStop()
        }
    }

    internal func restart(port: UInt16) async {
        await lifecycle.run { [weak self] in
            guard let self else { return }
            await self.performStop()
            await self.performStart(port: port)
        }
    }

    internal func lazyStart() async {
        await lifecycle.run { [weak self] in
            guard let self, !self.isRunning else { return }
            await self.performStart(port: UInt16(clamping: AppSettingsManager.shared.mcp.port))
        }
    }

    internal func scheduleStart(port: UInt16) {
        lifecycle.enqueue { [weak self] in
            await self?.performStart(port: port)
        }
    }

    internal func scheduleStop() {
        lifecycle.enqueue { [weak self] in
            await self?.performStop()
        }
    }

    internal func scheduleRestart(port: UInt16) {
        lifecycle.enqueue { [weak self] in
            guard let self else { return }
            await self.performStop()
            await self.performStart(port: port)
        }
    }

    internal func disconnectClient(_ clientId: String) async {
        guard let composition else { return }
        let entries = await composition.activityLedger.snapshot(now: Date())

        guard let tokenId = entries.first(where: { $0.id == clientId })?.tokenId else {
            await composition.activityLedger.forget(id: clientId)
            await refreshClients()
            return
        }

        await tokenStore?.revoke(tokenId: tokenId)
        await composition.authPolicy.clearApprovals(tokenId: tokenId)
        await composition.activityLedger.forget(tokenId: tokenId)
        await refreshClients()
    }

    private func performStart(port: UInt16) async {
        if composition != nil {
            await performStop()
        }

        handshake.removeIfAbandoned()

        generation += 1
        let generation = self.generation
        state = .starting

        let store = MCPTokenStore()
        await store.loadFromDisk()
        tokenStore = store

        let settings = AppSettingsManager.shared.mcp
        var lastFailure = ""

        for candidate in MCPPortAllocator.candidates(preferred: Int(port)) {
            let built = MCPServerComposition.build(port: candidate, settings: settings, tokenStore: store)
            do {
                try await built.transport.start()
            } catch {
                lastFailure = error.localizedDescription
                await built.transport.stop()
                continue
            }
            guard self.generation == generation else {
                await built.transport.stop()
                return
            }
            await activate(built, generation: generation, store: store)
            return
        }

        let failure = MCPPortAllocatorError.everyCandidateRejected(lastFailure: lastFailure)
        Self.logger.error("MCP server failed to start: \(lastFailure, privacy: .public)")
        state = .failed(failure.localizedDescription)
        tokenStore = nil
    }

    private func activate(_ built: MCPServerComposition, generation: Int, store: MCPTokenStore) async {
        guard let boundPort = await built.transport.listeningPort else {
            await built.transport.stop()
            state = .failed(String(localized: "The MCP server started without a port"))
            tokenStore = nil
            return
        }

        guard let credential = await mintBridgeCredential(store: store) else {
            await built.transport.stop()
            state = .failed(String(localized: "The MCP server could not issue its bridge credential"))
            tokenStore = nil
            return
        }

        composition = built
        bridgeCredential = credential
        instanceId = MCPServerInstanceIdentity.shared.begin()

        await built.start()
        startDispatchLoop(built, generation: generation)
        startStateLoop(built, generation: generation)
        startClientRefresh(built, generation: generation)
        startBridgeCredentialRenewal(generation: generation)
        await registerRevocationObserver(built, store: store, generation: generation)

        writeHandshake(port: boundPort, credential: credential)
        state = .running(port: boundPort)
        MCPAuditLogger.logServerStarted(port: boundPort)
    }

    private func performStop() async {
        await MCPAuditLogger.flush()
        guard let composition else {
            if tokenStore != nil {
                await releaseBridgeCredential()
                tokenStore = nil
            }
            state = .stopped
            return
        }

        generation += 1
        self.composition = nil

        dispatchTask?.cancel()
        dispatchTask = nil
        stateTask?.cancel()
        stateTask = nil
        clientRefreshTask?.cancel()
        clientRefreshTask = nil
        tokenRenewalTask?.cancel()
        tokenRenewalTask = nil

        handshake.removeIfWrittenByThisProcess(instanceId: instanceId)
        MCPServerInstanceIdentity.shared.end()
        instanceId = ""

        if let observerId = revocationObserverId {
            await tokenStore?.removeRevocationObserver(observerId)
            revocationObserverId = nil
        }

        await composition.teardown()
        await releaseBridgeCredential()

        tokenStore = nil
        connectedClients = []
        state = .stopped
        MCPAuditLogger.logServerStopped()
    }

    private func mintBridgeCredential(store: MCPTokenStore) async -> BridgeCredential? {
        let expiresAt = Date().addingTimeInterval(Self.bridgeTokenLifetime)
        do {
            let generated = try await store.generate(
                name: MCPTokenStore.stdioBridgeTokenName,
                permissions: MCPTokenStore.bridgeTokenPermissions,
                connectionAccess: .all,
                expiresAt: expiresAt
            )
            return BridgeCredential(
                tokenId: generated.token.id,
                plaintext: generated.plaintext,
                expiresAt: expiresAt
            )
        } catch {
            Self.logger.error("Bridge credential minting failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func releaseBridgeCredential() async {
        guard let credential = bridgeCredential else { return }
        bridgeCredential = nil
        await tokenStore?.delete(tokenId: credential.tokenId)
    }

    private func startBridgeCredentialRenewal(generation: Int) {
        let delay = Self.bridgeTokenLifetime - Self.bridgeTokenRenewalLead
        tokenRenewalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.renewBridgeCredential(generation: generation)
            }
        }
    }

    private func renewBridgeCredential(generation: Int) async {
        guard self.generation == generation,
              let store = tokenStore,
              case .running(let port) = state else { return }

        let previous = bridgeCredential
        guard let credential = await mintBridgeCredential(store: store) else { return }

        guard self.generation == generation else {
            await store.delete(tokenId: credential.tokenId)
            return
        }

        bridgeCredential = credential
        writeHandshake(port: port, credential: credential)

        if let previous {
            await store.delete(tokenId: previous.tokenId)
        }
        Self.logger.info("Rotated the MCP bridge credential")
    }

    private func writeHandshake(port: UInt16, credential: BridgeCredential) {
        handshake.write(
            MCPHandshakePayload(
                port: Int(port),
                token: credential.plaintext,
                pid: ProcessInfo.processInfo.processIdentifier,
                instanceId: instanceId,
                protocolVersion: MCPProtocolVersion.latest.rawValue,
                expiresAt: credential.expiresAt
            )
        )
    }

    private func startDispatchLoop(_ built: MCPServerComposition, generation: Int) {
        let dispatcher = built.dispatcher
        dispatchTask = Task { @MainActor [weak self] in
            for await exchange in built.transport.exchanges {
                guard let self, self.isCurrent(generation) else { return }
                Task { await dispatcher.dispatch(exchange) }
            }
        }
    }

    private func startStateLoop(_ built: MCPServerComposition, generation: Int) {
        stateTask = Task { @MainActor [weak self] in
            for await transportState in built.transport.listenerState {
                guard let self else { return }
                self.applyTransportState(transportState, generation: generation)
            }
        }
    }

    private func startClientRefresh(_ built: MCPServerComposition, generation: Int) {
        clientRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isCurrent(generation) else { return }
                await self.refreshClients()
                try? await Task.sleep(for: Self.clientRefreshInterval)
            }
        }
    }

    private func registerRevocationObserver(
        _ built: MCPServerComposition,
        store: MCPTokenStore,
        generation: Int
    ) async {
        revocationObserverId = await store.addRevocationObserver { [weak self] rawTokenId in
            guard let tokenId = UUID(uuidString: rawTokenId), let self else { return }
            await self.handleTokenRevoked(tokenId: tokenId, dispatcher: built.dispatcher, generation: generation)
        }
    }

    private func handleTokenRevoked(
        tokenId: UUID,
        dispatcher: MCPProtocolDispatcher,
        generation: Int
    ) async {
        guard isCurrent(generation) else { return }
        let cancelled = await dispatcher.cancelInflight(matchingTokenId: tokenId)
        await composition?.authPolicy.clearApprovals(tokenId: tokenId)
        guard cancelled > 0 else { return }
        Self.logger.info(
            "Token \(tokenId.uuidString, privacy: .public) revoked: cancelled \(cancelled, privacy: .public) request(s)"
        )
    }

    private func applyTransportState(_ transportState: MCPHttpServerState, generation: Int) {
        guard isCurrent(generation) else { return }
        switch transportState {
        case .idle, .stopped:
            state = .stopped
        case .starting:
            state = .starting
        case .running(let port):
            state = .running(port: port)
        case .failed(let reason):
            state = .failed(reason)
            lifecycle.enqueue { [weak self] in
                await self?.performStop()
                self?.state = .failed(reason)
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func refreshClients() async {
        guard let composition else {
            connectedClients = []
            return
        }
        let now = Date()
        await composition.activityLedger.prune(now: now)
        let entries = await composition.activityLedger.snapshot(now: now)
        connectedClients = entries.map { entry in
            SessionSnapshot(
                id: entry.id,
                clientName: entry.clientName,
                clientVersion: entry.clientVersion,
                connectedSince: entry.firstSeenAt,
                lastActivityAt: entry.lastSeenAt,
                tokenName: entry.tokenName,
                remoteAddress: entry.address
            )
        }
    }
}
