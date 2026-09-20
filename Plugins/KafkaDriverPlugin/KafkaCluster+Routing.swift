import Foundation

/// One partition's answer inside a reply that carries several.
///
/// Kafka batches by partition and answers by partition: a ListOffsets sent to a broker that
/// leads four of a topic's six partitions comes back with four offsets and two error codes, in
/// one successful response. Reading that as a single throwing result is what shipped #2993,
/// where the first error code discarded the partitions that had answered correctly.
enum KafkaPartitionOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case rejected(code: Int16)
    case failed(KafkaError)
}

extension KafkaPartitionOutcome {
    /// Every partition's value, or the error that best explains the ones missing.
    ///
    /// The bootstrap-only translation lives here because it is the one place that knows both
    /// the routing setting and which partitions came back short. "This broker no longer leads
    /// the partition" is a true statement a user can do nothing with; naming the setting that
    /// kept the client on one broker is actionable.
    static func requireAll(
        _ outcomes: [Int32: KafkaPartitionOutcome<Value>],
        topic: String,
        api: String,
        routing: KafkaBrokerRouting
    ) throws -> [Int32: Value] {
        var values: [Int32: Value] = [:]
        var ledElsewhere: [Int32] = []
        var rejected: [Int32: Int16] = [:]
        var firstFailure: KafkaError?

        for (partition, outcome) in outcomes {
            switch outcome {
            case .value(let value):
                values[partition] = value
            case .rejected(let code):
                if routing == .bootstrapOnly, code == KafkaErrorCode.notLeaderOrFollower {
                    ledElsewhere.append(partition)
                } else {
                    rejected[partition] = code
                }
            case .failed(let error):
                if firstFailure == nil { firstFailure = error }
            }
        }

        if !ledElsewhere.isEmpty {
            throw KafkaError.partitionsLedElsewhere(topic: topic, partitions: ledElsewhere)
        }
        if let code = rejected.values.min() {
            let affected = rejected.filter { $0.value == code }.map(\.key)
            throw KafkaError.partitionsRejected(topic: topic, partitions: affected, api: api, code: code)
        }
        if let firstFailure { throw firstFailure }
        return values
    }

    /// How an error thrown by one broker's sub-request is recorded against its partitions.
    ///
    /// A body that reports an error code by throwing still has to reach the retry. Fetch and
    /// Produce name one partition and check its code inline, so folding their throw into
    /// `.failed` would take away the refresh-and-retry they have always had.
    static func outcome(for error: KafkaError) -> KafkaPartitionOutcome<Value> {
        guard case .broker(let code, _) = error else { return .failed(error) }
        return .rejected(code: code)
    }
}

extension KafkaCluster {
    /// Runs a request against the leader of every partition it names, in as few requests as
    /// there are leaders.
    ///
    /// A Kafka client is told each partition's leader by Metadata and must address the leader
    /// directly; a broker answers NOT_LEADER_OR_FOLLOWER for a partition it does not lead and
    /// forwards nothing. The partitions of one topic have different leaders, so a batched
    /// per-partition request has to be split along that boundary, which is the whole of #2993.
    ///
    /// One retry, after re-reading Metadata, for the partitions whose code says the cluster
    /// moved rather than that the request was wrong. Re-resolving the leader covers the
    /// transient codes too: where the leader has not changed, the retry lands on the same
    /// connection, which is what `retrySameBroker` asks for anyway.
    func withLeaders<Value: Sendable>(
        topic: String,
        partitions: [Int32],
        api: String,
        _ body: @Sendable @escaping (KafkaConnection, [Int32]) async throws
            -> [Int32: KafkaPartitionOutcome<Value>]
    ) async throws -> [Int32: KafkaPartitionOutcome<Value>] {
        let wanted = Set(partitions).sorted()
        guard !wanted.isEmpty else { return [:] }

        var merged = try await routeOneRound(topic: topic, partitions: wanted, refresh: false, body: body)
        let moved = wanted.filter { partition in
            guard case .rejected(let code) = merged[partition] else { return false }
            switch KafkaErrorCode.retryAction(for: code) {
            case .resolveLeaderAgain, .retrySameBroker: return true
            case .report, .findCoordinatorAgain: return false
            }
        }
        guard !moved.isEmpty else { return merged }

        invalidateMetadata()
        let second = try await routeOneRound(topic: topic, partitions: moved, refresh: true, body: body)
        merged.merge(second) { _, retried in retried }
        return merged
    }

    /// The single-partition case, so there is one implementation of resolve, split and retry.
    func withLeader<Value: Sendable>(
        of partition: Int32,
        topic: String,
        api: String,
        _ body: @Sendable @escaping (KafkaConnection) async throws -> Value
    ) async throws -> Value {
        let outcomes = try await withLeaders(topic: topic, partitions: [partition], api: api) { connection, _ in
            [partition: .value(try await body(connection))]
        }
        let values = try KafkaPartitionOutcome.requireAll(
            outcomes,
            topic: topic,
            api: api,
            routing: routing
        )
        guard let value = values[partition] else {
            throw KafkaError.producedToUnknownPartition(topic: topic, partition: partition)
        }
        return value
    }

    private func routeOneRound<Value: Sendable>(
        topic: String,
        partitions: [Int32],
        refresh: Bool,
        body: @Sendable @escaping (KafkaConnection, [Int32]) async throws
            -> [Int32: KafkaPartitionOutcome<Value>]
    ) async throws -> [Int32: KafkaPartitionOutcome<Value>] {
        try Task.checkCancellation()
        let leaders = try await leaderMap(topic: topic, refresh: refresh)

        var outcomes: [Int32: KafkaPartitionOutcome<Value>] = [:]
        var unknown: [Int32] = []
        var byLeader: [Int32: [Int32]] = [:]
        for partition in partitions {
            guard let leader = leaders[partition] else {
                unknown.append(partition)
                continue
            }
            // A partition between leader elections reports -1. It is not an unreachable broker
            // and not a rejection, so it is reported as itself rather than routed anywhere.
            guard leader >= 0 else {
                outcomes[partition] = .failed(.partitionsHaveNoLeader(topic: topic, partitions: [partition]))
                continue
            }
            byLeader[leader, default: []].append(partition)
        }
        if !unknown.isEmpty {
            throw KafkaError.unknownPartitions(
                topic: topic,
                partitions: unknown,
                available: leaders.keys.sorted()
            )
        }

        // Resolve every leader before sending anything. A resolve can dial, and dialling
        // suspends, so interleaving one leader's resolve with another's send would let two
        // requests reach one connection. Grouping by connection identity rather than by leader
        // is what makes bootstrap-only routing and a shared endpoint safe: several leaders
        // collapsing onto one connection become one request, not several racing ones.
        var plan: [(connection: KafkaConnection, partitions: [Int32])] = []
        var slotForConnection: [ObjectIdentifier: Int] = [:]
        for leader in byLeader.keys.sorted() {
            let group = byLeader[leader] ?? []
            do {
                let connection = try await connection(forLeader: leader)
                let identity = ObjectIdentifier(connection)
                if let slot = slotForConnection[identity] {
                    plan[slot].partitions.append(contentsOf: group)
                } else {
                    slotForConnection[identity] = plan.count
                    plan.append((connection, group))
                }
            } catch let error as KafkaError {
                for partition in group { outcomes[partition] = .failed(error) }
            }
        }

        // No child throws. A thrown error would exit the group and cancel its siblings, and
        // `KafkaConnection.send` closes its channel on cancellation, so one leader's failure
        // would tear down the healthy connections serving the others.
        await withTaskGroup(of: [Int32: KafkaPartitionOutcome<Value>].self) { group in
            for entry in plan {
                let connection = entry.connection
                let slice = entry.partitions.sorted()
                group.addTask {
                    do {
                        return try await body(connection, slice)
                    } catch let error as KafkaError {
                        let outcome = KafkaPartitionOutcome<Value>.outcome(for: error)
                        return Dictionary(uniqueKeysWithValues: slice.map { ($0, outcome) })
                    } catch {
                        let wrapped = KafkaError.connectionFailed(error.localizedDescription)
                        return Dictionary(uniqueKeysWithValues: slice.map { ($0, .failed(wrapped)) })
                    }
                }
            }
            for await answered in group {
                outcomes.merge(answered) { _, new in new }
            }
        }
        return outcomes
    }

    /// Each partition's leader, from the routing cache or a fresh Metadata read.
    func leaderMap(topic: String, refresh: Bool) async throws -> [Int32: Int32] {
        if !refresh, let cached = leadersByTopic[topic], !cached.isEmpty { return cached }
        if refresh { leadersByTopic[topic] = nil }
        let metadata = try await metadata(topics: [topic], refresh: true)
        _ = try metadata.requireTopic(named: topic)
        guard let leaders = leadersByTopic[topic] else { throw KafkaError.unknownTopic(topic) }
        return leaders
    }

    // MARK: - Coordinator routing

    /// Runs a request against the broker that coordinates a consumer group.
    ///
    /// A group's committed offsets and its membership live on its coordinator, which is the
    /// broker owning the `__consumer_offsets` partition the group id hashes to. Every other
    /// broker answers NOT_COORDINATOR and forwards nothing, so FindCoordinator is not optional
    /// on a cluster with more than one broker. One retry, because a coordinator that has just
    /// moved or is still loading its log answers a code that says exactly that.
    func withCoordinator<Value: Sendable>(
        of group: String,
        _ body: @Sendable (KafkaConnection) async throws -> Value
    ) async throws -> Value {
        do {
            return try await body(try await coordinatorConnection(for: group, refresh: false))
        } catch let error as KafkaError {
            guard case .broker(let code, _) = error,
                  KafkaErrorCode.retryAction(for: code) == .findCoordinatorAgain else { throw error }
            coordinatorsByGroup[group] = nil
            return try await body(try await coordinatorConnection(for: group, refresh: true))
        }
    }

    /// The groups each broker coordinates, for a request that names several.
    ///
    /// DescribeGroups is batched but coordinator-scoped, so a list spanning three coordinators
    /// is three requests, not one, and asking any single broker for all of them answers
    /// NOT_COORDINATOR per group for the ones it does not hold.
    func groupsByCoordinator(_ groups: [String]) async throws -> [(connection: KafkaConnection, groups: [String])] {
        var byNode: [Int32: [String]] = [:]
        for group in Set(groups).sorted() {
            let nodeId = try await coordinatorNode(for: group, refresh: false)
            byNode[nodeId, default: []].append(group)
        }
        var plan: [(connection: KafkaConnection, groups: [String])] = []
        var slotForConnection: [ObjectIdentifier: Int] = [:]
        for nodeId in byNode.keys.sorted() {
            let held = byNode[nodeId] ?? []
            let connection = try await connection(forLeader: nodeId)
            let identity = ObjectIdentifier(connection)
            if let slot = slotForConnection[identity] {
                plan[slot].groups.append(contentsOf: held)
            } else {
                slotForConnection[identity] = plan.count
                plan.append((connection, held))
            }
        }
        return plan
    }

    private func coordinatorNode(for group: String, refresh: Bool) async throws -> Int32 {
        if !refresh, let cached = coordinatorsByGroup[group] { return cached }
        let nodeId = try await KafkaFindCoordinatorRequest.coordinator(
            forGroup: group,
            on: try await controlConnection()
        )
        coordinatorsByGroup[group] = nodeId
        return nodeId
    }

    private func coordinatorConnection(for group: String, refresh: Bool) async throws -> KafkaConnection {
        if !refresh, let cached = coordinatorsByGroup[group] {
            if let connection = try? await connection(forLeader: cached) { return connection }
            coordinatorsByGroup[group] = nil
        }
        return try await connection(forLeader: try await coordinatorNode(for: group, refresh: true))
    }

    // MARK: - Cluster-wide sweeps

    /// Runs a request against every broker and collects what each one says.
    ///
    /// ListGroups is the reason this exists: a broker answers it with the groups it coordinates
    /// and nothing else, with no error and no hint that the rest of the cluster holds more, so
    /// a client that asks one broker reports a fraction of the groups as though it were all of
    /// them. `reachedEveryBroker` is what lets the caller say the list is short rather than
    /// present a partial answer as complete.
    func withEveryBroker<Value: Sendable>(
        _ body: @Sendable @escaping (KafkaConnection) async throws -> Value
    ) async throws -> (results: [Value], reachedEveryBroker: Bool) {
        let reachable = try await everyBrokerConnection()
        var collected: [Value] = []
        var answered = 0

        await withTaskGroup(of: Optional<Value>.self) { group in
            for connection in reachable.connections {
                group.addTask { try? await body(connection) }
            }
            for await value in group {
                guard let value else { continue }
                answered += 1
                collected.append(value)
            }
        }
        guard answered > 0 else { throw KafkaError.notConnected }
        return (collected, answered >= reachable.expected)
    }
}
