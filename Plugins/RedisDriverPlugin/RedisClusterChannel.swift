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
//  Redis Cluster serves database 0 alone. Valkey 9 serves numbered databases in cluster mode when
//  `cluster-databases` is above 1, each node keeping its own selected database, so the channel
//  owns where the whole cluster belongs and every node moves there before its next command.
//

import Foundation
import os
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisClusterChannel")

/// One node's connection, as the cluster channel drives it.
protocol RedisClusterNodeConnection: RedisCommandChannel {
    func adoptRouting(_ newRouting: RedisCommandRouting)
    /// Where the node's session belongs, which the cluster sets for every node at once. The node
    /// moves there before its next command that is not part of a visit.
    func adoptHomeDatabase(_ index: Int)
}

typealias RedisClusterNodeFactory = @Sendable (RedisNodeAddress) -> any RedisClusterNodeConnection

final class RedisClusterChannel: RedisCommandChannel, @unchecked Sendable {
    private enum Limits {
        static let maxRedirects = 5
        static let maxBusyRetries = 3
        static let busyBackoff: UInt64 = 100_000_000
        static let topologyReloadEveryNthRedirect = 5
    }

    private let seeds: [RedisNodeAddress]
    private let openNode: RedisClusterNodeFactory

    private let lock = NSLock()
    private var connections: [String: any RedisClusterNodeConnection] = [:]
    private var topology = RedisClusterTopology(shards: [])
    private var routing = RedisCommandRouting()
    private var redirectsSinceReload = 0
    private var isShuttingDown = false
    private var cachedVersion: String?
    private var home = 0
    private var servedDatabases = 1

    init(seeds: [RedisNodeAddress], openNode: @escaping RedisClusterNodeFactory) {
        self.seeds = seeds
        self.openNode = openNode
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !connections.isEmpty
    }

    var supportsDatabaseSelection: Bool { servedDatabaseCount > 1 }

    private var servedDatabaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return servedDatabases
    }

    /// Redis refuses MULTI's queued commands with MOVED whenever they hash outside the node the
    /// transaction opened on, and the driver has to pick that node before it has seen a key. On a
    /// three-shard cluster that aborts most single-slot transactions, so the honest answer is that
    /// the grid saves its rows one statement at a time instead.
    var supportsTransactions: Bool { false }

    var partitionsKeyspace: Bool { true }

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
        home = 0
        servedDatabases = 1
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

    func currentDatabase() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return home
    }

    /// The first primary answers for the cluster, since every primary serves the same databases,
    /// and the rest follow before their next command. A block open on it holds the SELECT back:
    /// queued there it would move that one primary when EXEC runs and leave the others behind.
    func selectDatabase(_ index: Int, scope: RedisCommandScope) async throws {
        guard supportsDatabaseSelection else {
            guard index == 0 else { throw Self.singleDatabaseRefusal }
            return
        }
        guard let primary = snapshotState().topology.orderedMasters.first else {
            throw RedisPluginError.notConnected
        }
        try await connection(to: primary.address).selectDatabase(index, scope: .outsideBlock)
        adoptHome(index)
    }

    /// Every node reads the visit before each command it sends, so there is nothing to move here.
    func visitDatabase(_ index: Int) async throws {
        guard supportsDatabaseSelection || index == 0 else { throw Self.singleDatabaseRefusal }
    }

    func reportedDatabaseCount() async throws -> Int? {
        servedDatabaseCount
    }

    /// `INFO keyspace` describes the node that answers it, so each primary's is read and added up.
    func keyCountsByDatabase() async throws -> [Int: Int]? {
        guard supportsDatabaseSelection else { return try await databaseZeroKeyCounts() }
        var perPrimary: [[Int: Int]?] = []
        for primary in snapshotState().topology.orderedMasters {
            perPrimary.append(try await connection(to: primary.address).keyspaceKeyCounts())
        }
        return RedisClusterAggregator.keyspace(perPrimary)
    }

    private func adoptHome(_ index: Int) {
        lock.lock()
        home = index
        lock.unlock()
    }

    private func adoptServedDatabases(_ count: Int) {
        lock.lock()
        servedDatabases = count
        lock.unlock()
    }

    // MARK: - Command dispatch

    func executeCommand(_ args: [Data], scope: RedisCommandScope) async throws -> RedisReply {
        guard !args.isEmpty else { return .null }
        let snapshot = snapshotState()
        let spec = snapshot.routing.spec(for: args)

        switch spec?.clusterFanOut ?? .single {
        case .everyNode:
            return try await broadcast(args, to: snapshot.topology.allNodes, spec: spec, scope: scope)
        case .everyPrimary:
            return try await broadcast(args, to: snapshot.topology.masters, spec: spec, scope: scope)
        case .keyedShards:
            return try await runMultiShard(args, spec: spec, snapshot: snapshot, scope: scope)
        case .single:
            return try await routeSingle(args, spec: spec, snapshot: snapshot, scope: scope)
        }
    }

    func executePipeline(_ commands: [[Data]], scope: RedisCommandScope) async throws -> [RedisReply] {
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
            let batch = try await connection.executePipeline(entries.map(\.command), scope: scope)
            for (entry, reply) in zip(entries, batch) {
                replies[entry.index] = try await resolveRedirectIfNeeded(
                    reply,
                    command: entry.command,
                    from: address,
                    scope: scope
                )
            }
        }
        return replies
    }

    func scanKeyspace(
        cursor: String,
        pattern: String?,
        type: String?,
        count: Int,
        scope: RedisCommandScope
    ) async throws -> RedisKeyspacePage {
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
            let reply = try await connection.executeCommand(args, scope: scope).throwIfError().throwIfQueued("SCAN")
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

    private func routeSingle(
        _ args: [Data],
        spec: RedisCommandSpec?,
        snapshot: Snapshot,
        scope: RedisCommandScope
    ) async throws -> RedisReply {
        if spec?.hasMovableKeys == true, let resolved = try? await serverResolvedKeys(for: args, snapshot: snapshot) {
            guard RedisKeySlot.slotsAreEqual(for: resolved) else {
                throw RedisPluginError(code: 0, message: Self.crossSlotMessage(for: args))
            }
            if let first = resolved.first,
               let node = snapshot.topology.master(forSlot: RedisKeySlot.slot(for: first)) {
                return try await send(args, to: node.address, scope: scope)
            }
        }
        guard let node = try owningNode(for: args, snapshot: snapshot) else {
            return try await routeToAnyMaster(args, snapshot: snapshot, scope: scope)
        }
        return try await send(args, to: node.address, scope: scope)
    }

    private func routeToAnyMaster(_ args: [Data], snapshot: Snapshot, scope: RedisCommandScope) async throws -> RedisReply {
        guard let node = snapshot.topology.orderedMasters.first else { throw RedisPluginError.notConnected }
        return try await send(args, to: node.address, scope: scope)
    }

    private func runMultiShard(
        _ args: [Data],
        spec: RedisCommandSpec?,
        snapshot: Snapshot,
        scope: RedisCommandScope
    ) async throws -> RedisReply {
        guard let spec else { return try await routeSingle(args, spec: nil, snapshot: snapshot, scope: scope) }
        guard let groups = RedisMultiShardPlanner.split(arguments: args, spec: spec) else {
            return try await routeSingle(args, spec: spec, snapshot: snapshot, scope: scope)
        }

        let targets = try groups.map { group in
            guard let node = snapshot.topology.master(forSlot: group.slot) else {
                throw RedisPluginError.notConnected
            }
            return node.address
        }
        let replies = try await sendParts(
            groups.map(\.arguments),
            to: targets,
            carrying: groups.map { group in group.keyIndices.map { args[$0] } },
            of: args,
            isWrite: spec.isWrite,
            followRedirects: true,
            scope: scope
        )

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
        spec: RedisCommandSpec?,
        scope: RedisCommandScope
    ) async throws -> RedisReply {
        let targets = (nodes.isEmpty ? snapshotState().topology.masters : nodes).map(\.address)
        guard !targets.isEmpty else { throw RedisPluginError.notConnected }
        let replies = try await sendParts(
            Array(repeating: args, count: targets.count),
            to: targets,
            carrying: [],
            of: args,
            isWrite: spec?.changesEveryNodeItReaches ?? false,
            followRedirects: false,
            scope: scope
        )
        return RedisClusterAggregator.combine(replies, policy: spec?.responsePolicy)
    }

    /// Nothing ties the parts of a split command together, so each runs on its own node and one
    /// can be refused after another has already run. A write whose parts disagree is reported
    /// with what ran, because the refusing part's reply alone reads as if nothing did. Every
    /// owner is known before this is called, so a part is never stranded by a slot with no owner.
    private func sendParts(
        _ parts: [[Data]],
        to targets: [RedisNodeAddress],
        carrying keys: [[Data]],
        of args: [Data],
        isWrite: Bool,
        followRedirects: Bool,
        scope: RedisCommandScope
    ) async throws -> [RedisReply] {
        let command = Self.commandName(of: args)
        let nodes = targets.map(\.identifier)
        var replies: [RedisReply] = []
        replies.reserveCapacity(parts.count)
        for (part, target) in zip(parts, targets) {
            do {
                replies.append(try await send(part, to: target, followRedirects: followRedirects, scope: scope))
            } catch where !(error is CancellationError) {
                noteShardFailures(of: command, replies: replies, nodes: targets)
                guard let partial = RedisPartialClusterWrite.assemble(
                    command: command, isWrite: isWrite, nodes: nodes, keys: keys,
                    replies: replies, interruption: error
                ) else { throw error }
                throw notePartialWrite(partial)
            }
        }
        noteShardFailures(of: command, replies: replies, nodes: targets)
        if let partial = RedisPartialClusterWrite.assemble(
            command: command, isWrite: isWrite, nodes: nodes, keys: keys,
            replies: replies, interruption: nil
        ) {
            throw notePartialWrite(partial)
        }
        return replies
    }

    /// The reply the user sees is one shard's own, which names neither the node nor the other
    /// shards, so the log keeps both. The class only, because the rest of an error message can
    /// quote a key.
    private func noteShardFailures(of command: String, replies: [RedisReply], nodes: [RedisNodeAddress]) {
        for (position, (reply, node)) in zip(replies, nodes).enumerated() {
            guard let message = reply.errorMessage else { continue }
            let errorClass = RedisConnectProbe.errorClass(of: message)
            let part = "\(node.identifier), part \(position + 1) of \(nodes.count)"
            logger.notice("\(command, privacy: .public) failed on \(part, privacy: .public): \(errorClass, privacy: .public)")
        }
    }

    private func notePartialWrite(_ partial: RedisPartialClusterWrite) -> RedisPartialClusterWrite {
        let applied = partial.appliedParts.count
        logger.notice(
            "\(partial.command, privacy: .public) partly applied: \(applied, privacy: .public) of \(partial.parts.count, privacy: .public)"
        )
        return partial
    }

    private static func commandName(of args: [Data]) -> String {
        args.first.flatMap { String(data: $0, encoding: .utf8) }?.uppercased() ?? ""
    }

    private func serverResolvedKeys(for args: [Data], snapshot: Snapshot) async throws -> [Data] {
        guard let node = snapshot.topology.orderedMasters.first else { return [] }
        var request: [Data] = [Data("COMMAND".utf8), Data("GETKEYS".utf8)]
        request.append(contentsOf: args)
        let reply = try await send(request, to: node.address, followRedirects: false, scope: .outsideBlock)
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
        followRedirects: Bool = true,
        scope: RedisCommandScope
    ) async throws -> RedisReply {
        var target = address
        var redirects = 0
        var busyRetries = 0

        while true {
            let connection = try await connection(to: target)
            let reply = try await connection.executeCommand(args, scope: scope)
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
                return try await sendAsking(args, to: asked, scope: scope)
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
    private func sendAsking(_ args: [Data], to address: RedisNodeAddress, scope: RedisCommandScope) async throws -> RedisReply {
        let connection = try await connection(to: address)
        let replies = try await connection.executePipeline([[Data("ASKING".utf8)], args], scope: scope)
        return replies.last ?? .null
    }

    private func resolveRedirectIfNeeded(
        _ reply: RedisReply,
        command: [Data],
        from address: RedisNodeAddress,
        scope: RedisCommandScope
    ) async throws -> RedisReply {
        guard let message = reply.errorMessage,
              let redirect = RedisClusterRedirect.parse(message, fallbackHost: address.host) else {
            return reply
        }
        switch redirect {
        case .moved(let slot, let moved):
            noteMoved(slot: slot, to: moved)
            return try await send(command, to: moved, scope: scope)
        case .ask(_, let asked):
            return try await sendAsking(command, to: asked, scope: scope)
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

    private func adoptRoutingTable(_ table: RedisCommandRouting) -> [any RedisClusterNodeConnection] {
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

    /// Every node is handed the cluster's database each time it is handed out, so a node that has
    /// not run a command since the cluster moved, or one opened afterwards, catches up before it
    /// sends anything. Connecting starts a session on database 0, so the database follows it.
    private func connection(to address: RedisNodeAddress) async throws -> any RedisClusterNodeConnection {
        let existing = try reusableConnection(to: address)
        if let connection = existing.connection {
            connection.adoptHomeDatabase(existing.home)
            return connection
        }

        let opened = openNode(address)
        opened.adoptRouting(existing.routing)
        try await opened.connect()
        opened.adoptHomeDatabase(existing.home)

        guard let replaced = store(opened, at: address) else {
            opened.disconnect()
            throw RedisPluginError.notConnected
        }
        replaced.previous?.disconnect()
        return opened
    }

    private func reusableConnection(
        to address: RedisNodeAddress
    ) throws -> (connection: (any RedisClusterNodeConnection)?, routing: RedisCommandRouting, home: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { throw RedisPluginError.notConnected }
        if let existing = connections[address.identifier], existing.isConnected {
            return (existing, routing, home)
        }
        return (nil, routing, home)
    }

    private func store(
        _ connection: any RedisClusterNodeConnection,
        at address: RedisNodeAddress
    ) -> (previous: (any RedisClusterNodeConnection)?, Void)? {
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

        let shardsReply = try await connection.executeCommand(["CLUSTER", "SHARDS"], scope: .outsideBlock)
        if let parsed = RedisClusterTopologyParser.parseShards(shardsReply, fallbackHost: seed.host) {
            return parsed
        }
        if let message = shardsReply.errorMessage, message.contains("cluster support disabled") {
            throw RedisPluginError(code: 0, message: RedisTopologyDiagnostics.notAClusterMessage)
        }

        let slotsReply = try await connection.executeCommand(["CLUSTER", "SLOTS"], scope: .outsideBlock)
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
            let info = (try? await connection.executeCommand(["INFO", "server"], scope: .outsideBlock))?.stringValue
            adoptVersion(info.flatMap(RedisServerInfo.version(from:)))
        }

        let served = await databasesServed(by: discovered.orderedMasters)
        adoptServedDatabases(served)
        logger.info("Cluster serves \(served, privacy: .public) database(s)")
    }

    /// Measured on Valkey 9.1.2, `cluster-databases` answers the count each node serves and cannot
    /// change at runtime, while Redis 8.10.1 answers an empty list for a setting it does not have.
    /// The fewest any primary serves is the count, because a database one primary lacks cannot
    /// hold the keys that hash to it. A primary that declines CONFIG says nothing either way.
    private func databasesServed(by primaries: [RedisClusterNode]) async -> Int {
        var replies: [RedisReply?] = []
        for primary in primaries {
            let reply = try? await connection(to: primary.address)
                .runMetadataRead(["CONFIG", "GET", "cluster-databases"])
            replies.append(reply)
        }
        return RedisDatabaseCount.servedByCluster(primaryReplies: replies)
    }

    /// One COMMAND at connect rather than a lookup per unknown command. The full answer is about
    /// 110 KB for 300 commands in a single round trip, and a user whose ACL denies COMMAND is
    /// denied CLUSTER SLOTS too, so there is no case where lazy lookups would have helped.
    private func fetchRouting(from seed: RedisNodeAddress) async throws -> RedisCommandRouting {
        let connection = try await connection(to: seed)
        let reply = try await connection.executeCommand(["COMMAND"], scope: .outsideBlock)
        guard let parsed = RedisCommandRouting.parse(commandReply: reply) else {
            logger.notice("COMMAND unavailable; using the curated routing table")
            return RedisCommandRouting()
        }
        return parsed
    }

    // MARK: - Messages

    private static var singleDatabaseRefusal: RedisPluginError {
        RedisPluginError(
            code: 0,
            message: String(localized: "This cluster serves database 0 only, so it cannot switch databases.")
        )
    }

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
