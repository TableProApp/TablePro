import Foundation
import NIOCore
import NIOPosix
import os
import TableProPluginKit

/// Owns the connections to a cluster: the bootstrap dial, the per-broker pool, and the routing
/// rule that decides whether a partition leader is reachable at its advertised address.
///
/// The routing rule is not a nicety. A Kafka client is told the cluster's membership by
/// Metadata, and those advertised addresses are frequently unreachable from where the client
/// sits: behind an SSH tunnel there is one forwarded port, and a broker advertising
/// `kafka-1.internal:9092` cannot be dialled at all. TablePro already solves the same problem
/// for its other topology-aware drivers by pinning them (MongoDB to `directConnection`, Redis
/// to `standalone`) whenever a tunnel rewrites the host, and Kafka joins that rule.
///
/// Which broker a request goes to is a property of the request, not a preference. Kafka has
/// four answers and this type offers one primitive for each: any broker (`controlConnection`),
/// the partition leader (`withLeaders`), the group coordinator (`withCoordinator`), and every
/// broker at once (`withEveryBroker`). See `KafkaCluster+Routing.swift`.
actor KafkaCluster {
    private static let logger = Logger(subsystem: "com.TablePro", category: "KafkaCluster")

    private let bootstrap: [KafkaEndpoint]
    private let ssl: SSLConfiguration
    private let credentials: KafkaCredentials
    let routing: KafkaBrokerRouting
    private let connectTimeout: TimeAmount
    private let group: EventLoopGroup

    private var connections: [KafkaEndpoint: KafkaConnection] = [:]
    /// The dial in progress for an endpoint, so a second caller awaits the first instead of
    /// opening a rival socket. `connection(forLeader:)` reads the pool, awaits `open()` and
    /// only then writes the pool, and an actor releases its executor across that await: two
    /// callers routing to the same leader both saw an empty pool, both dialled, and the second
    /// overwrote the first's entry, leaking its socket. Fanning one request out per leader
    /// makes that race routine rather than rare.
    private var dialsInFlight: [KafkaEndpoint: Task<KafkaConnection, Error>] = [:]
    /// Bumped by every disconnect. A dial suspends, so one that succeeds after the pool has been
    /// drained would otherwise put its socket back into an emptied pool that nothing will ever
    /// close, and its cleanup would remove a newer caller's entry.
    private var poolGeneration = 0
    /// Why a broker could not be dialled, remembered so a six-partition browse does not pay the
    /// connect timeout once per partition. Cleared whenever Metadata is re-read, because that is
    /// when a broker's advertised address can have changed.
    private var unreachableBrokers: [Int32: String] = [:]
    private var bootstrapConnection: KafkaConnection?
    private var cachedMetadata: KafkaClusterMetadata?
    private var brokersById: [Int32: KafkaBroker] = [:]
    /// Partition to leader, per topic, for routing only. Deliberately separate from
    /// `cachedMetadata`: six callers read `metadata(topics:)` expecting a live answer for
    /// DESCRIBE TOPIC and the sidebar counts, and caching that call would change all of them.
    var leadersByTopic: [String: [Int32: Int32]] = [:]
    var coordinatorsByGroup: [String: Int32] = [:]

    init(
        bootstrap: [KafkaEndpoint],
        ssl: SSLConfiguration,
        credentials: KafkaCredentials,
        routing: KafkaBrokerRouting,
        connectTimeoutSeconds: Int
    ) {
        self.bootstrap = bootstrap
        self.ssl = ssl
        self.credentials = credentials
        self.routing = routing
        connectTimeout = .seconds(Int64(max(1, connectTimeoutSeconds)))
        // The process-wide group rather than a private one. A private group is released only
        // by disconnect(), and the app calls that on a cancelled connect but not on a failed
        // one, so every rejected credential leaked a thread.
        group = NIOSingletons.posixEventLoopGroup
    }

    /// Dials the first bootstrap endpoint that answers. A cluster is usually given as several
    /// addresses precisely because any one of them may be down.
    ///
    /// A bootstrap connection that has since closed is re-dialled rather than kept. The guard
    /// used to be `bootstrapConnection == nil`, so one cancelled statement closed the channel
    /// (`send`'s cancellation handler does) and every later call threw `notConnected` for the
    /// life of the session with nothing able to heal it.
    func connect() async throws {
        if let bootstrapConnection, await bootstrapConnection.isOpen { return }
        bootstrapConnection = nil
        var failures: [String] = []
        for endpoint in bootstrap {
            try Task.checkCancellation()
            let connection = KafkaConnection(endpoint: endpoint, clientId: KafkaClientInfo.clientId)
            do {
                try await connection.open(ssl: ssl, credentials: credentials, group: group, timeout: connectTimeout)
                bootstrapConnection = connection
                connections[endpoint] = connection
                return
            } catch {
                await connection.close()
                failures.append("\(endpoint.description): \(error.localizedDescription)")
            }
        }
        throw KafkaError.connectionFailed(failures.joined(separator: "; "))
    }

    func disconnect() async {
        poolGeneration &+= 1
        for dial in dialsInFlight.values { dial.cancel() }
        dialsInFlight.removeAll()
        for connection in connections.values {
            await connection.close()
        }
        connections.removeAll()
        bootstrapConnection = nil
        cachedMetadata = nil
        brokersById.removeAll()
        leadersByTopic.removeAll()
        coordinatorsByGroup.removeAll()
        unreachableBrokers.removeAll()
    }

    func bootstrapEndpointDescription() -> String {
        bootstrap.map(\.description).joined(separator: ",")
    }

    /// A connection to a broker that can answer a request addressed to no broker in particular:
    /// Metadata, ApiVersions and FindCoordinator.
    func controlConnection() async throws -> KafkaConnection {
        if let bootstrapConnection, await bootstrapConnection.isOpen { return bootstrapConnection }
        try await connect()
        guard let bootstrapConnection else { throw KafkaError.notConnected }
        return bootstrapConnection
    }

    /// The connection to the broker that is currently the controller.
    ///
    /// A ZooKeeper-mode cluster accepts an admin request such as DeleteTopics only on the
    /// controller and answers NOT_CONTROLLER anywhere else. A KRaft cluster forwards it
    /// (KIP-590) and fills Metadata's `controllerId` with a randomly chosen live broker, so this
    /// dials an arbitrary broker there and it does not matter. The silent fall back to the
    /// bootstrap connection is kept for that reason, and only here: an admin request reaching
    /// the "wrong" broker is answered on every cluster this driver supports, which is not true
    /// of a partition read.
    func controllerConnection() async throws -> KafkaConnection {
        let metadata = try await metadata()
        guard metadata.controllerId >= 0 else { return try await controlConnection() }
        do {
            return try await connection(forLeader: metadata.controllerId)
        } catch {
            return try await controlConnection()
        }
    }

    /// The connection to use for a partition whose leader is `nodeId`.
    ///
    /// Under `bootstrapOnly` this always returns the bootstrap connection, which will answer
    /// NOT_LEADER_OR_FOLLOWER for a partition it does not lead. The caller turns that into an
    /// error naming the setting rather than the error code, because "this broker no longer leads
    /// the partition" tells a user nothing they can act on.
    ///
    /// An advertised address that cannot be dialled is reported. It used to fall back to the
    /// bootstrap connection with a log line, which guaranteed NOT_LEADER_OR_FOLLOWER and blamed
    /// leadership for what was a reachability problem.
    func connection(forLeader nodeId: Int32) async throws -> KafkaConnection {
        guard routing == .advertised else { return try await controlConnection() }
        guard let broker = brokersById[nodeId] else { return try await controlConnection() }
        if let reason = unreachableBrokers[nodeId] {
            throw KafkaError.brokerUnreachable(nodeId: nodeId, address: broker.endpoint.description, reason: reason)
        }
        if let existing = connections[broker.endpoint], await existing.isOpen { return existing }

        do {
            return try await dial(broker.endpoint)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            unreachableBrokers[nodeId] = reason
            Self.logger.warning("""
            Broker \(nodeId, privacy: .public) advertises an address this client cannot reach
            """)
            throw KafkaError.brokerUnreachable(nodeId: nodeId, address: broker.endpoint.description, reason: reason)
        }
    }

    /// Every broker the cluster reports, for a request each broker answers only for itself.
    ///
    /// Brokers that cannot be dialled are skipped rather than failing the sweep, and the count
    /// that came back is returned so the caller can say the answer is partial. Under
    /// `bootstrapOnly` that is one broker out of however many the cluster has.
    func everyBrokerConnection() async throws -> (connections: [KafkaConnection], expected: Int) {
        let metadata = try await metadata()
        let expected = max(1, metadata.brokers.count)
        guard routing == .advertised else {
            return ([try await controlConnection()], expected)
        }
        // Deduplicated by connection identity, not by broker id. Several brokers can advertise
        // one address, and asking the same socket three times and counting three answers is how
        // a partial sweep would report itself as complete, which is the defect this exists to
        // fix rather than repeat.
        var reachable: [KafkaConnection] = []
        var seen: Set<ObjectIdentifier> = []
        for broker in metadata.brokers.sorted(by: { $0.nodeId < $1.nodeId }) {
            guard let connection = try? await connection(forLeader: broker.nodeId) else { continue }
            guard seen.insert(ObjectIdentifier(connection)).inserted else { continue }
            reachable.append(connection)
        }
        if reachable.isEmpty { reachable = [try await controlConnection()] }
        return (reachable, expected)
    }

    private func dial(_ endpoint: KafkaEndpoint) async throws -> KafkaConnection {
        let generation = poolGeneration
        if let running = dialsInFlight[endpoint] {
            let connection = try await running.value
            return try await install(connection, at: endpoint, from: generation)
        }
        let ssl = ssl
        let credentials = credentials
        let group = group
        let timeout = connectTimeout
        let dial = Task { () async throws -> KafkaConnection in
            let connection = KafkaConnection(endpoint: endpoint, clientId: KafkaClientInfo.clientId)
            do {
                try await connection.open(ssl: ssl, credentials: credentials, group: group, timeout: timeout)
            } catch {
                await connection.close()
                throw error
            }
            return connection
        }
        dialsInFlight[endpoint] = dial
        let connection: KafkaConnection
        do {
            connection = try await dial.value
        } catch {
            if poolGeneration == generation { dialsInFlight[endpoint] = nil }
            throw error
        }
        if poolGeneration == generation { dialsInFlight[endpoint] = nil }
        return try await install(connection, at: endpoint, from: generation)
    }

    /// Puts a freshly dialled connection into the pool, unless the pool moved on while it was
    /// being dialled. A connection nobody will own is closed here rather than leaked.
    private func install(
        _ connection: KafkaConnection,
        at endpoint: KafkaEndpoint,
        from generation: Int
    ) async throws -> KafkaConnection {
        guard poolGeneration == generation else {
            await connection.close()
            throw KafkaError.notConnected
        }
        connections[endpoint] = connection
        return connection
    }

    func metadata(topics: [String]? = nil, refresh: Bool = false) async throws -> KafkaClusterMetadata {
        if !refresh, let cachedMetadata, topics == nil { return cachedMetadata }
        let connection = try await controlConnection()
        let fetched = try await KafkaMetadataRequest.fetch(topics: topics, on: connection)
        adopt(fetched, cacheAll: topics == nil)
        return fetched
    }

    /// Records what a Metadata reply says about the cluster's shape.
    ///
    /// A fresh reply is also the only moment a broker's advertised address can have changed, so
    /// it is where the unreachable list is cleared: a broker that moves to an address this client
    /// can reach must not stay marked from the old one.
    func adopt(_ metadata: KafkaClusterMetadata, cacheAll: Bool) {
        if cacheAll { cachedMetadata = metadata }
        for broker in metadata.brokers { brokersById[broker.nodeId] = broker }
        for topic in metadata.topics where !topic.name.isEmpty {
            leadersByTopic[topic.name] = Dictionary(
                topic.partitions.map { ($0.index, $0.leader) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        unreachableBrokers.removeAll()
    }

    func invalidateMetadata() {
        cachedMetadata = nil
        leadersByTopic.removeAll()
        coordinatorsByGroup.removeAll()
        unreachableBrokers.removeAll()
    }
}
