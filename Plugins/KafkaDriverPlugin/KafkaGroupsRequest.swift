import Foundation

struct KafkaGroupSummary: Sendable {
    let groupId: String
    let protocolType: String
    let state: String
}

struct KafkaGroupListing: Sendable {
    let groups: [KafkaGroupSummary]
    /// False when at least one broker could not be asked. A group list assembled from some of
    /// the cluster's brokers is missing whole groups rather than being merely out of date.
    let isComplete: Bool
}

struct KafkaGroupMember: Sendable {
    let memberId: String
    let clientId: String
    let clientHost: String
}

struct KafkaGroupDetail: Sendable {
    let groupId: String
    let state: String
    let protocolType: String
    let assignmentProtocol: String
    let members: [KafkaGroupMember]

    /// Kafka answers a group it has never heard of with state "Dead" and no members rather
    /// than with an error, so this is the only thing that separates a typo from a group that
    /// simply has not committed anything yet.
    var isKnown: Bool { state.caseInsensitiveCompare("Dead") != .orderedSame }
}

struct KafkaGroupOffset: Sendable {
    let topic: String
    let partition: Int32
    let committedOffset: Int64
}

/// The consumer-group side of the cluster, which is what makes Kafka debuggable: a group's lag
/// is the gap between what has been written and what the group has acknowledged.
///
/// Every request here is coordinator-scoped. A group's state and committed offsets live on the
/// broker that owns the `__consumer_offsets` partition its id hashes to, and no other broker
/// will answer for it or forward the question: measured on a three-broker cluster, a
/// non-coordinator answers OffsetFetch with a group-level NOT_COORDINATOR and DescribeGroups
/// with NOT_COORDINATOR per group. ListGroups is worse than that, because it succeeds: a broker
/// lists the groups it coordinates and says nothing about the rest, so asking one broker
/// reports a third of a three-broker cluster's groups as though that were all of them.
enum KafkaGroupsRequest {
    /// Every group on the cluster, by asking every broker.
    static func listGroups(cluster: KafkaCluster) async throws -> KafkaGroupListing {
        let swept = try await cluster.withEveryBroker { connection in
            try await listGroups(on: connection)
        }
        var byId: [String: KafkaGroupSummary] = [:]
        for summary in swept.results.flatMap({ $0 }) {
            byId[summary.groupId] = summary
        }
        return KafkaGroupListing(
            groups: byId.values.sorted { $0.groupId < $1.groupId },
            isComplete: swept.reachedEveryBroker
        )
    }

    private static func listGroups(on connection: KafkaConnection) async throws -> [KafkaGroupSummary] {
        let version = try await connection.negotiatedVersion(for: .listGroups)
        let flexible = KafkaApiKey.listGroups.isFlexible(version: version)

        let request = KafkaRequest(api: .listGroups, version: version) { writer, _ in
            if version >= 4 {
                if flexible {
                    writer.compactArrayCount(0)                    // statesFilter: every state
                } else {
                    writer.legacyArrayCount(0)
                }
            }
            if flexible { writer.emptyTaggedFields() }
        }

        var body = try await connection.send(request)
        if version >= 1 { _ = try body.int32() }                   // throttleTimeMs
        let errorCode = try body.int16()
        try KafkaErrorCode.check(errorCode, api: "ListGroups")

        return try body.array(compact: flexible) { reader -> KafkaGroupSummary in
            let groupId = flexible ? try reader.compactString() : try reader.legacyString()
            let protocolType = flexible ? try reader.compactString() : try reader.legacyString()
            var state = ""
            if version >= 4 {
                state = (flexible ? try reader.nullableCompactString() : try reader.nullableLegacyString()) ?? ""
            }
            if flexible { try reader.taggedFields() }
            return KafkaGroupSummary(groupId: groupId, protocolType: protocolType, state: state)
        }
    }

    /// A group's state and its members, asked of each group's coordinator.
    static func describeGroups(_ groupIds: [String], cluster: KafkaCluster) async throws -> [KafkaGroupDetail] {
        guard !groupIds.isEmpty else { return [] }
        let details = try await cluster.withCoordinators(of: groupIds) { connection, held in
            try await describeGroups(held, on: connection)
        }
        return details.sorted { $0.groupId < $1.groupId }
    }

    private static func describeGroups(
        _ groupIds: [String],
        on connection: KafkaConnection
    ) async throws -> [KafkaGroupDetail] {
        let version = try await connection.negotiatedVersion(for: .describeGroups)
        let flexible = KafkaApiKey.describeGroups.isFlexible(version: version)

        let request = KafkaRequest(api: .describeGroups, version: version) { writer, _ in
            writer.array(groupIds, compact: flexible) { itemWriter, groupId in
                if flexible {
                    itemWriter.compactString(groupId)
                } else {
                    itemWriter.legacyString(groupId)
                }
            }
            if version >= 3 { writer.boolean(false) }              // includeAuthorizedOperations
            if flexible { writer.emptyTaggedFields() }
        }

        var body = try await connection.send(request)
        if version >= 1 { _ = try body.int32() }                   // throttleTimeMs

        // Parsed in full before any error code is acted on. Throwing from inside the array
        // closure abandons the reader mid-reply, so one group's NOT_COORDINATOR used to discard
        // every group already read beside it.
        let parsed = try body.array(compact: flexible) { reader -> (KafkaGroupDetail, Int16) in
            let errorCode = try reader.int16()
            let groupId = flexible ? try reader.compactString() : try reader.legacyString()
            let state = flexible ? try reader.compactString() : try reader.legacyString()
            let protocolType = flexible ? try reader.compactString() : try reader.legacyString()
            let assignmentProtocol = flexible ? try reader.compactString() : try reader.legacyString()
            let members = try reader.array(compact: flexible) { memberReader -> KafkaGroupMember in
                let memberId = flexible ? try memberReader.compactString() : try memberReader.legacyString()
                if version >= 4 {
                    _ = flexible
                        ? try memberReader.nullableCompactString()
                        : try memberReader.nullableLegacyString()   // groupInstanceId
                }
                let clientId = flexible ? try memberReader.compactString() : try memberReader.legacyString()
                let clientHost = flexible ? try memberReader.compactString() : try memberReader.legacyString()
                _ = flexible ? try memberReader.nullableCompactBytes() : try memberReader.nullableLegacyBytes()
                _ = flexible ? try memberReader.nullableCompactBytes() : try memberReader.nullableLegacyBytes()
                if flexible { try memberReader.taggedFields() }
                return KafkaGroupMember(memberId: memberId, clientId: clientId, clientHost: clientHost)
            }
            if version >= 3 { _ = try reader.int32() }             // authorizedOperations
            if flexible { try reader.taggedFields() }
            return (
                KafkaGroupDetail(
                    groupId: groupId,
                    state: state,
                    protocolType: protocolType,
                    assignmentProtocol: assignmentProtocol,
                    members: members
                ),
                errorCode
            )
        }

        if let rejected = parsed.first(where: { $0.1 != KafkaErrorCode.none }) {
            try KafkaErrorCode.check(rejected.1, api: "DescribeGroups")
        }
        return parsed.map(\.0)
    }

    /// A group's committed offsets, asked of its coordinator.
    static func fetchCommittedOffsets(group: String, cluster: KafkaCluster) async throws -> [KafkaGroupOffset] {
        try await cluster.withCoordinator(of: group) { connection in
            try await fetchCommittedOffsets(group: group, on: connection)
        }
    }

    private static func fetchCommittedOffsets(
        group: String,
        on connection: KafkaConnection
    ) async throws -> [KafkaGroupOffset] {
        let version = try await connection.negotiatedVersion(for: .offsetFetch)
        let flexible = KafkaApiKey.offsetFetch.isFlexible(version: version)

        let request = KafkaRequest(api: .offsetFetch, version: version) { writer, _ in
            if version >= 8 {
                // v8 moved to a batched shape: a list of groups, each with its own topic list.
                writer.compactArrayCount(1)
                writer.compactString(group)
                writer.compactArrayCount(nil)                      // null topics: every topic
                writer.emptyTaggedFields()
                writer.boolean(false)                              // requireStable
                writer.emptyTaggedFields()
            } else {
                if flexible {
                    writer.compactString(group)
                    writer.compactArrayCount(nil)
                } else {
                    writer.legacyString(group)
                    writer.legacyArrayCount(nil)
                }
                if version >= 7 { writer.boolean(false) }
                if flexible { writer.emptyTaggedFields() }
            }
        }

        var body = try await connection.send(request)
        if version >= 3 { _ = try body.int32() }                   // throttleTimeMs

        if version >= 8 {
            let groups = try body.array(compact: true) { reader -> ([KafkaGroupOffset], [Int16]) in
                _ = try reader.compactString()                     // groupId
                let read = try readTopics(&reader, version: version, flexible: true)
                let errorCode = try reader.int16()
                try reader.taggedFields()
                return (read.offsets, read.errorCodes + [errorCode])
            }
            try reportFirstFailure(groups.flatMap(\.1))
            return groups.flatMap(\.0)
        }

        let read = try readTopics(&body, version: version, flexible: flexible)
        var codes = read.errorCodes
        if version >= 2 { codes.append(try body.int16()) }
        try reportFirstFailure(codes)
        return read.offsets
    }

    private static func reportFirstFailure(_ codes: [Int16]) throws {
        guard let failed = codes.first(where: { $0 != KafkaErrorCode.none }) else { return }
        try KafkaErrorCode.check(failed, api: "OffsetFetch")
    }

    /// Reads the topic list and carries every partition's error code back rather than throwing
    /// mid-parse.
    ///
    /// The reader has to reach the end of the reply either way: throwing from inside the array
    /// closure abandons it part-read, and at v8 the group's own error code sits AFTER its
    /// topics, so the caller would never see it. A partition that did report an error still
    /// fails the call, at `reportFirstFailure`, once everything has been read.
    private static func readTopics(
        _ reader: inout KafkaProtocolReader,
        version: Int16,
        flexible: Bool
    ) throws -> (offsets: [KafkaGroupOffset], errorCodes: [Int16]) {
        let topics = try reader.array(compact: flexible) { topicReader -> [(KafkaGroupOffset, Int16)] in
            let name = flexible ? try topicReader.compactString() : try topicReader.legacyString()
            let partitions = try topicReader.array(compact: flexible) { partitionReader -> (KafkaGroupOffset, Int16) in
                let index = try partitionReader.int32()
                let committed = try partitionReader.int64()
                if version >= 5 { _ = try partitionReader.int32() }   // committedLeaderEpoch
                _ = flexible
                    ? try partitionReader.nullableCompactString()
                    : try partitionReader.nullableLegacyString()      // metadata
                let errorCode = try partitionReader.int16()
                if flexible { try partitionReader.taggedFields() }
                return (
                    KafkaGroupOffset(topic: name, partition: index, committedOffset: committed),
                    errorCode
                )
            }
            if flexible { try topicReader.taggedFields() }
            return partitions
        }
        let flat = topics.flatMap { $0 }
        return (flat.filter { $0.1 == KafkaErrorCode.none }.map(\.0), flat.map(\.1))
    }
}
