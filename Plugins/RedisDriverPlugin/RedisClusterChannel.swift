//
//  RedisClusterChannel.swift
//  RedisDriverPlugin
//
//  Slot routing over one hiredis connection per cluster node.
//
//  hiredis has no cluster support at all, so the routing lives here. Holding several contexts at
//  once is fine: measured at 6 concurrent connections driven from 6 threads, 1200 commands, no
//  errors. A MOVED or ASK arrives as an ordinary error reply with the context still usable, so a
//  redirect costs a re-dispatch and never a reconnect.
//

import Foundation
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisClusterChannel")

final class RedisClusterChannel: RedisCommandChannel, @unchecked Sendable {
    private enum Limits {
        static let maxRedirects = 5
        static let maxBusyRetries = 3
        static let busyBackoff: UInt64 = 100_000_000
        static let topologyReloadEveryNthRedirect = 5
    }

    private let seeds: [RedisNodeAddress]
    private let username: String?
    private let password: String?
    private let sslConfig: SSLConfiguration
    private let connectTimeout: TimeInterval

    private let lock = NSLock()
    private var connections: [String: RedisPluginConnection] = [:]
    private var topology = RedisClusterTopology(shards: [])
    private var routing = RedisCommandRouting()
    private var redirectsSinceReload = 0
    private var isShuttingDown = false
    private var cachedVersion: String?

    init(
        seeds: [RedisNodeAddress],
        username: String?,
        password: String?,
        sslConfig: SSLConfiguration,
        connectTimeout: TimeInterval = 5
    ) {
        self.seeds = seeds
        self.username = username
        self.password = password
        self.sslConfig = sslConfig
        self.connectTimeout = connectTimeout
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !connections.isEmpty
    }

    var supportsDatabaseSelection: Bool { false }

    /// Redis refuses MULTI's queued commands with MOVED whenever they hash outside the node the
    /// transaction opened on, and the driver has to pick that node before it has seen a key. On a
    /// three-shard cluster that aborts most single-slot transactions, so the honest answer is that
    /// the grid saves its rows one statement at a time instead.
    var supportsTransactions: Bool { false }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {
        guard !seeds.isEmpty else {
            throw RedisPluginError(code: 0, message: String(localized: "Cluster mode needs at least one seed node."))
        }
        report(.custom(String(localized: "Discovering cluster topology")))

        var lastError: Error?
        for seed in seeds {
            do {
                let discovered = try await discoverTopology(from: seed, reportingStage: report)
                try await adopt(discovered, discoveredFrom: seed)
                logger.info("Cluster topology: \(discovered.shards.count, privacy: .public) shards")
                return
            } catch {
                lastError = error
                logger.debug("Seed \(seed.identifier, privacy: .public) did not answer: \(error.localizedDescription)")
            }
        }
        throw lastError ?? RedisPluginError.connectionFailed
    }

    func disconnect() {
        lock.lock()
        isShuttingDown = true
        let open = Array(connections.values)
        connections.removeAll()
        topology = RedisClusterTopology(shards: [])
        lock.unlock()
        open.forEach { $0.disconnect() }
    }

    func cancelCurrentQuery() {
        lock.lock()
        let open = Array(connections.values)
        lock.unlock()
        open.forEach { $0.cancelCurrentQuery() }
    }

    func serverVersion() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedVersion
    }

    func currentDatabase() -> Int { 0 }

    func selectDatabase(_ index: Int) async throws {
        guard index == 0 else {
            throw RedisPluginError(
                code: 0,
                message: String(localized: "Redis Cluster serves database 0 only, so it cannot switch databases.")
            )
        }
    }

    // MARK: - Command dispatch

    func executeCommand(_ args: [Data]) async throws -> RedisReply {
        guard !args.isEmpty else { return .null }
        let snapshot = snapshotState()
        let spec = snapshot.routing.spec(for: args)

        switch spec?.requestPolicy {
        case .allNodes:
            return try await broadcast(args, to: snapshot.topology.allNodes, policy: spec?.responsePolicy)
        case .allShards:
            guard spec?.responsePolicy != .special else {
                return try await routeToAnyMaster(args, snapshot: snapshot)
            }
            return try await broadcast(args, to: snapshot.topology.masters, policy: spec?.responsePolicy)
        case .multiShard:
            return try await runMultiShard(args, spec: spec, snapshot: snapshot)
        case .special, .none:
            return try await routeSingle(args, spec: spec, snapshot: snapshot)
        }
    }

    func executePipeline(_ commands: [[Data]]) async throws -> [RedisReply] {
        guard !commands.isEmpty else { return [] }
        let snapshot = snapshotState()

        var order: [String] = []
        var grouped: [String: [(index: Int, command: [Data])]] = [:]
        for (index, command) in commands.enumerated() {
            let target = try routeTarget(for: command, snapshot: snapshot)
            if grouped[target] == nil {
                order.append(target)
                grouped[target] = []
            }
            grouped[target]?.append((index, command))
        }

        var replies = [RedisReply](repeating: .null, count: commands.count)
        for target in order {
            guard let entries = grouped[target], let address = address(forIdentifier: target) else { continue }
            let connection = try await connection(to: address)
            let batch = try await connection.executePipeline(entries.map(\.command))
            for (entry, reply) in zip(entries, batch) {
                replies[entry.index] = try await resolveRedirectIfNeeded(
                    reply,
                    command: entry.command,
                    from: address
                )
            }
        }
        return replies
    }

    func scanKeyspace(cursor: String, pattern: String?, type: String?, count: Int) async throws -> RedisKeyspacePage {
        let snapshot = snapshotState()
        let ordered = snapshot.topology.orderedMasters
        let nodeIds = ordered.map(\.id)

        switch RedisClusterCursor.decode(cursor, orderedNodeIds: nodeIds) {
        case .finished:
            return RedisKeyspacePage(cursor: RedisClusterCursor.start, keys: [], isIncomplete: false)
        case .node(let id, let nodeCursor, let restarted):
            guard let node = ordered.first(where: { $0.id == id }) else {
                return RedisKeyspacePage(cursor: RedisClusterCursor.start, keys: [], isIncomplete: true)
            }
            var args = ["SCAN", nodeCursor]
            if let pattern { args += ["MATCH", pattern] }
            args += ["COUNT", String(count)]
            if let type { args += ["TYPE", type] }

            let connection = try await connection(to: node.address)
            let reply = try await connection.executeCommand(args).throwIfError()
            let page = RedisScanReply.parse(reply)
            let next = RedisClusterCursor.advance(
                after: node.id,
                nodeCursor: page.cursor,
                orderedNodeIds: nodeIds
            )
            return RedisKeyspacePage(cursor: next, keys: page.keys, isIncomplete: restarted)
        }
    }

    // MARK: - Routing

    private struct Snapshot {
        let topology: RedisClusterTopology
        let routing: RedisCommandRouting
    }

    private func snapshotState() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(topology: topology, routing: routing)
    }

    private func routeTarget(for args: [Data], snapshot: Snapshot) throws -> String {
        guard let node = try owningNode(for: args, snapshot: snapshot) else {
            guard let fallback = snapshot.topology.orderedMasters.first else {
                throw RedisPluginError.notConnected
            }
            return fallback.address.identifier
        }
        return node.address.identifier
    }

    /// A command with no key, or one whose keys the static positions cannot express, goes to an
    /// arbitrary master. Guessing that the first argument is a key is worse than not guessing:
    /// a keyless container command like SCRIPT LOAD would be hashed on the literal "LOAD" and
    /// answered by one node with +OK, and no MOVED ever comes back to correct it.
    private func owningNode(for args: [Data], snapshot: Snapshot) throws -> RedisClusterNode? {
        let keys = snapshot.routing.keys(in: args)
        guard let first = keys.first else { return nil }
        guard RedisKeySlot.slotsAreEqual(for: keys) else {
            throw RedisPluginError(code: 0, message: Self.crossSlotMessage(for: args))
        }
        return snapshot.topology.master(forSlot: RedisKeySlot.slot(for: first))
    }

    private func routeSingle(_ args: [Data], spec: RedisCommandSpec?, snapshot: Snapshot) async throws -> RedisReply {
        if spec?.hasMovableKeys == true, let resolved = try? await serverResolvedKeys(for: args, snapshot: snapshot) {
            guard RedisKeySlot.slotsAreEqual(for: resolved) else {
                throw RedisPluginError(code: 0, message: Self.crossSlotMessage(for: args))
            }
            if let first = resolved.first,
               let node = snapshot.topology.master(forSlot: RedisKeySlot.slot(for: first)) {
                return try await send(args, to: node.address)
            }
        }
        guard let node = try owningNode(for: args, snapshot: snapshot) else {
            return try await routeToAnyMaster(args, snapshot: snapshot)
        }
        return try await send(args, to: node.address)
    }

    private func routeToAnyMaster(_ args: [Data], snapshot: Snapshot) async throws -> RedisReply {
        guard let node = snapshot.topology.orderedMasters.first else { throw RedisPluginError.notConnected }
        return try await send(args, to: node.address)
    }

    private func runMultiShard(_ args: [Data], spec: RedisCommandSpec?, snapshot: Snapshot) async throws -> RedisReply {
        guard let spec else { return try await routeSingle(args, spec: nil, snapshot: snapshot) }
        guard let groups = RedisMultiShardPlanner.split(arguments: args, spec: spec) else {
            return try await routeSingle(args, spec: spec, snapshot: snapshot)
        }

        var replies: [RedisReply] = []
        replies.reserveCapacity(groups.count)
        for group in groups {
            guard let node = snapshot.topology.master(forSlot: group.slot) else {
                throw RedisPluginError.notConnected
            }
            replies.append(try await send(group.arguments, to: node.address))
        }

        guard let policy = spec.responsePolicy else {
            return RedisMultiShardPlanner.scatterInKeyOrder(
                groups: groups,
                replies: replies,
                keyIndices: spec.keyIndices(forArgumentCount: args.count)
            )
        }
        return RedisClusterAggregator.combine(replies, policy: policy)
    }

    private func broadcast(
        _ args: [Data],
        to nodes: [RedisClusterNode],
        policy: RedisResponsePolicy?
    ) async throws -> RedisReply {
        let targets = nodes.isEmpty ? snapshotState().topology.masters : nodes
        guard !targets.isEmpty else { throw RedisPluginError.notConnected }
        var replies: [RedisReply] = []
        replies.reserveCapacity(targets.count)
        for node in targets {
            replies.append(try await send(args, to: node.address, followRedirects: false))
        }
        return RedisClusterAggregator.combine(replies, policy: policy)
    }

    private func serverResolvedKeys(for args: [Data], snapshot: Snapshot) async throws -> [Data] {
        guard let node = snapshot.topology.orderedMasters.first else { return [] }
        var request: [Data] = [Data("COMMAND".utf8), Data("GETKEYS".utf8)]
        request.append(contentsOf: args)
        let reply = try await send(request, to: node.address, followRedirects: false)
        guard case .array(let items) = reply else { return [] }
        return items.compactMap { item in
            switch item {
            case .data(let value): return value
            case .string(let text), .status(let text): return Data(text.utf8)
            default: return nil
            }
        }
    }

    // MARK: - Sending

    private func send(
        _ args: [Data],
        to address: RedisNodeAddress,
        followRedirects: Bool = true
    ) async throws -> RedisReply {
        var target = address
        var redirects = 0
        var busyRetries = 0

        while true {
            let connection = try await connection(to: target)
            let reply = try await connection.executeCommand(args)
            guard followRedirects, let message = reply.errorMessage,
                  let redirect = RedisClusterRedirect.parse(message, fallbackHost: target.host) else {
                return reply
            }

            switch redirect {
            case .moved(let slot, let moved):
                guard redirects < Limits.maxRedirects else { return reply }
                redirects += 1
                noteMoved(slot: slot, to: moved)
                target = moved
            case .ask(_, let asked):
                guard redirects < Limits.maxRedirects else { return reply }
                redirects += 1
                return try await sendAsking(args, to: asked)
            case .tryAgain(let slot):
                guard busyRetries < Limits.maxBusyRetries else {
                    throw RedisPluginError(code: 0, message: Self.migrationMessage(slot: slot))
                }
                busyRetries += 1
                try await Task.sleep(nanoseconds: Limits.busyBackoff * UInt64(busyRetries))
            case .clusterDown(let detail):
                throw RedisPluginError(code: 0, message: Self.clusterDownMessage(detail: detail))
            case .crossSlot:
                throw RedisPluginError(code: 0, message: Self.crossSlotMessage(for: args))
            }
        }
    }

    /// ASKING is a one-shot flag, so it has to travel in the same pipeline as the command it
    /// applies to. Measured: sending it on its own leaves the next command answering MOVED.
    private func sendAsking(_ args: [Data], to address: RedisNodeAddress) async throws -> RedisReply {
        let connection = try await connection(to: address)
        let replies = try await connection.executePipeline([[Data("ASKING".utf8)], args])
        return replies.last ?? .null
    }

    private func resolveRedirectIfNeeded(
        _ reply: RedisReply,
        command: [Data],
        from address: RedisNodeAddress
    ) async throws -> RedisReply {
        guard let message = reply.errorMessage,
              let redirect = RedisClusterRedirect.parse(message, fallbackHost: address.host) else {
            return reply
        }
        switch redirect {
        case .moved(let slot, let moved):
            noteMoved(slot: slot, to: moved)
            return try await send(command, to: moved)
        case .ask(_, let asked):
            return try await sendAsking(command, to: asked)
        default:
            return reply
        }
    }

    private func noteMoved(slot: Int, to address: RedisNodeAddress) {
        lock.lock()
        redirectsSinceReload += 1
        let shouldReload = redirectsSinceReload >= Limits.topologyReloadEveryNthRedirect
        topology = topology.movingSlot(slot, to: address)
        if shouldReload { redirectsSinceReload = 0 }
        lock.unlock()
        guard shouldReload else { return }
        Task { [weak self] in await self?.reloadTopology() }
    }

    private func reloadTopology() async {
        let known = snapshotState().topology.masters.map(\.address) + seeds
        for address in known {
            guard let refreshed = try? await discoverTopology(from: address, reportingStage: { _ in }) else { continue }
            adoptTopology(refreshed)
            return
        }
    }

    private func adoptTopology(_ refreshed: RedisClusterTopology) {
        lock.lock()
        topology = refreshed
        lock.unlock()
    }

    private func adoptRoutingTable(_ table: RedisCommandRouting) -> [RedisPluginConnection] {
        lock.lock()
        routing = table
        let open = Array(connections.values)
        lock.unlock()
        return open
    }

    private func adoptVersion(_ version: String?) {
        lock.lock()
        cachedVersion = version
        lock.unlock()
    }

    // MARK: - Connections and discovery

    private func address(forIdentifier identifier: String) -> RedisNodeAddress? {
        snapshotState().topology.allNodes.first { $0.address.identifier == identifier }?.address
            ?? RedisClusterRedirect.parseEndpoint(identifier, fallbackHost: identifier)
    }

    private func connection(to address: RedisNodeAddress) async throws -> RedisPluginConnection {
        let existing = try reusableConnection(to: address)
        if let connection = existing.connection { return connection }

        let opened = RedisPluginConnection(
            host: address.host,
            port: address.port,
            username: username,
            password: password,
            database: 0,
            sslConfig: sslConfig,
            connectTimeout: connectTimeout
        )
        opened.adoptRouting(existing.routing)
        try await opened.connect()

        guard let replaced = store(opened, at: address) else {
            opened.disconnect()
            throw RedisPluginError.notConnected
        }
        replaced.previous?.disconnect()
        return opened
    }

    private func reusableConnection(
        to address: RedisNodeAddress
    ) throws -> (connection: RedisPluginConnection?, routing: RedisCommandRouting) {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { throw RedisPluginError.notConnected }
        if let existing = connections[address.identifier], existing.isConnected {
            return (existing, routing)
        }
        return (nil, routing)
    }

    private func store(
        _ connection: RedisPluginConnection,
        at address: RedisNodeAddress
    ) -> (previous: RedisPluginConnection?, Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { return nil }
        let previous = connections[address.identifier]
        connections[address.identifier] = connection
        return (previous, ())
    }

    private func discoverTopology(
        from seed: RedisNodeAddress,
        reportingStage report: @escaping ConnectionStageReporter
    ) async throws -> RedisClusterTopology {
        let connection = try await connection(to: seed)

        let shardsReply = try await connection.executeCommand(["CLUSTER", "SHARDS"])
        if let parsed = RedisClusterTopologyParser.parseShards(shardsReply, fallbackHost: seed.host) {
            return parsed
        }
        if let message = shardsReply.errorMessage, message.contains("cluster support disabled") {
            throw RedisPluginError(code: 0, message: RedisTopologyDiagnostics.notAClusterMessage)
        }

        let slotsReply = try await connection.executeCommand(["CLUSTER", "SLOTS"])
        if let message = slotsReply.errorMessage {
            if message.contains("cluster support disabled") {
                throw RedisPluginError(code: 0, message: RedisTopologyDiagnostics.notAClusterMessage)
            }
            throw RedisPluginError(code: 0, message: message)
        }
        guard let parsed = RedisClusterTopologyParser.parseSlots(slotsReply, fallbackHost: seed.host) else {
            throw RedisPluginError(
                code: 0,
                message: String(localized: "The cluster reported no slot coverage, so it has no data to browse yet.")
            )
        }
        return parsed
    }

    private func adopt(_ discovered: RedisClusterTopology, discoveredFrom seed: RedisNodeAddress) async throws {
        adoptTopology(discovered)

        if let table = try? await fetchRouting(from: seed) {
            adoptRoutingTable(table).forEach { $0.adoptRouting(table) }
        }

        for node in discovered.masters {
            _ = try await connection(to: node.address)
        }

        if let first = discovered.orderedMasters.first {
            let connection = try await connection(to: first.address)
            let info = (try? await connection.executeCommand(["INFO", "server"]))?.stringValue
            adoptVersion(info.flatMap(RedisServerInfo.version(from:)))
        }
    }

    /// One COMMAND at connect rather than a lookup per unknown command. The full answer is about
    /// 110 KB for 300 commands in a single round trip, and a user whose ACL denies COMMAND is
    /// denied CLUSTER SLOTS too, so there is no case where lazy lookups would have helped.
    private func fetchRouting(from seed: RedisNodeAddress) async throws -> RedisCommandRouting {
        let connection = try await connection(to: seed)
        let reply = try await connection.executeCommand(["COMMAND"])
        guard let parsed = RedisCommandRouting.parse(commandReply: reply) else {
            logger.notice("COMMAND unavailable; using the curated routing table")
            return RedisCommandRouting()
        }
        return parsed
    }

    // MARK: - Messages

    private static func crossSlotMessage(for args: [Data]) -> String {
        let name = args.first.flatMap { String(data: $0, encoding: .utf8) }?.uppercased() ?? "This command"
        let template = String(
            localized: "%@ needs every key in the same hash slot. Give the keys a shared hash tag, like {user}:1 and {user}:2."
        )
        return String(format: template, name)
    }

    private static func migrationMessage(slot: Int?) -> String {
        guard let slot else {
            return String(localized: "The cluster is moving keys between shards. Try again once the migration finishes.")
        }
        let template = String(
            localized: "The cluster is moving slot %d between shards. Try again once the migration finishes."
        )
        return String(format: template, slot)
    }

    private static func clusterDownMessage(detail: String) -> String {
        let template = String(localized: "The cluster is not serving requests: %@")
        return String(format: template, detail.isEmpty ? String(localized: "some slots have no owner") : detail)
    }
}
