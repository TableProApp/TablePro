import Foundation
import NIOCore
import NIOPosix
import TableProPluginKit
import os

/// Owns the connections to a cluster: the bootstrap dial, the per-broker pool, and the routing
/// rule that decides whether a partition leader is reachable at its advertised address.
///
/// The routing rule is not a nicety. A Kafka client is told the cluster's membership by
/// Metadata, and those advertised addresses are frequently unreachable from where the client
/// sits: behind an SSH tunnel there is one forwarded port, and a broker advertising
/// `kafka-1.internal:9092` cannot be dialled at all. TablePro already solves the same problem
/// for its other topology-aware drivers by pinning them (MongoDB to `directConnection`, Redis
/// to `standalone`) whenever a tunnel rewrites the host, and Kafka joins that rule.
actor KafkaCluster {
    private static let logger = Logger(subsystem: "com.TablePro", category: "KafkaCluster")

    private let bootstrap: [KafkaEndpoint]
    private let ssl: SSLConfiguration
    private let credentials: KafkaCredentials
    private let routing: KafkaBrokerRouting
    private let connectTimeout: TimeAmount
    private let group: EventLoopGroup

    private var connections: [KafkaEndpoint: KafkaConnection] = [:]
    private var bootstrapConnection: KafkaConnection?
    private var cachedMetadata: KafkaClusterMetadata?
    private var brokersById: [Int32: KafkaBroker] = [:]

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
    func connect() async throws {
        guard bootstrapConnection == nil else { return }
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
        for connection in connections.values {
            await connection.close()
        }
        connections.removeAll()
        bootstrapConnection = nil
        cachedMetadata = nil
        brokersById.removeAll()
    }

    func bootstrapEndpointDescription() -> String {
        bootstrap.map(\.description).joined(separator: ",")
    }

    func controlConnection() throws -> KafkaConnection {
        guard let bootstrapConnection else { throw KafkaError.notConnected }
        return bootstrapConnection
    }

    /// The connection to use for a partition whose leader is `nodeId`.
    ///
    /// Under `bootstrapOnly` this always returns the bootstrap connection. That can mean
    /// sending a Fetch to a broker that does not lead the partition, which answers
    /// NOT_LEADER_OR_FOLLOWER, and that is the honest outcome: the alternative is dialling an
    /// address that cannot be reached and reporting a timeout instead.
    func connection(forLeader nodeId: Int32) async throws -> KafkaConnection {
        guard routing == .advertised else { return try controlConnection() }
        guard let broker = brokersById[nodeId] else { return try controlConnection() }
        if let existing = connections[broker.endpoint], await existing.isOpen { return existing }

        let connection = KafkaConnection(endpoint: broker.endpoint, clientId: KafkaClientInfo.clientId)
        do {
            try await connection.open(ssl: ssl, credentials: credentials, group: group, timeout: connectTimeout)
        } catch {
            await connection.close()
            Self.logger.warning("""
            Broker \(nodeId, privacy: .public) advertises an address this client cannot reach; \
            falling back to the bootstrap connection
            """)
            return try controlConnection()
        }
        connections[broker.endpoint] = connection
        return connection
    }

    func metadata(topics: [String]? = nil, refresh: Bool = false) async throws -> KafkaClusterMetadata {
        if !refresh, let cachedMetadata, topics == nil { return cachedMetadata }
        let connection = try controlConnection()
        let fetched = try await KafkaMetadataRequest.fetch(topics: topics, on: connection)
        if topics == nil {
            cachedMetadata = fetched
        }
        for broker in fetched.brokers { brokersById[broker.nodeId] = broker }
        return fetched
    }

    func invalidateMetadata() {
        cachedMetadata = nil
    }

    /// Runs a request against the leader of a partition, refreshing metadata and retrying once
    /// when the cluster says the leadership moved. One retry, because a second failure is a
    /// real answer rather than a race.
    func withLeader<T>(
        of partition: Int32,
        topic: String,
        _ body: (KafkaConnection) async throws -> T
    ) async throws -> T {
        let leader = try await leaderNode(topic: topic, partition: partition)
        do {
            return try await body(try await connection(forLeader: leader))
        } catch let error as KafkaError {
            guard case .broker(let code, _) = error, KafkaErrorCode.requiresMetadataRefresh(code) else { throw error }
            invalidateMetadata()
            let refreshed = try await leaderNode(topic: topic, partition: partition, refresh: true)
            return try await body(try await connection(forLeader: refreshed))
        }
    }

    private func leaderNode(topic: String, partition: Int32, refresh: Bool = false) async throws -> Int32 {
        let meta = try await metadata(topics: [topic], refresh: refresh)
        let found = try meta.requireTopic(named: topic)
        guard let match = found.partitions.first(where: { $0.index == partition }) else {
            throw KafkaError.producedToUnknownPartition(topic: topic, partition: partition)
        }
        return match.leader
    }
}
