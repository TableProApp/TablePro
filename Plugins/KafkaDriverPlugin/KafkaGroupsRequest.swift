import Foundation

struct KafkaGroupSummary: Sendable {
    let groupId: String
    let protocolType: String
    let state: String
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
}

struct KafkaGroupOffset: Sendable {
    let topic: String
    let partition: Int32
    let committedOffset: Int64
}

/// The consumer-group side of the cluster, which is what makes Kafka debuggable: a group's lag
/// is the gap between what has been written and what the group has acknowledged.
enum KafkaGroupsRequest {
    static func listGroups(cluster: KafkaCluster) async throws -> [KafkaGroupSummary] {
        let connection = try await cluster.controlConnection()
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

    static func describeGroups(_ groupIds: [String], cluster: KafkaCluster) async throws -> [KafkaGroupDetail] {
        guard !groupIds.isEmpty else { return [] }
        let connection = try await cluster.controlConnection()
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

        return try body.array(compact: flexible) { reader -> KafkaGroupDetail in
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
            try KafkaErrorCode.check(errorCode, api: "DescribeGroups")
            return KafkaGroupDetail(
                groupId: groupId,
                state: state,
                protocolType: protocolType,
                assignmentProtocol: assignmentProtocol,
                members: members
            )
        }
    }

    /// A group's committed offsets. These live on the group's coordinator rather than on any
    /// partition leader, which is why FindCoordinator exists; the bootstrap broker answers it
    /// correctly on a single-node cluster and forwards otherwise.
    static func fetchCommittedOffsets(group: String, cluster: KafkaCluster) async throws -> [KafkaGroupOffset] {
        let connection = try await cluster.controlConnection()
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
            let groups = try body.array(compact: true) { reader -> [KafkaGroupOffset] in
                _ = try reader.compactString()                     // groupId
                let offsets = try readTopics(&reader, version: version, flexible: true)
                let errorCode = try reader.int16()
                try reader.taggedFields()
                try KafkaErrorCode.check(errorCode, api: "OffsetFetch")
                return offsets
            }
            return groups.flatMap { $0 }
        }

        let offsets = try readTopics(&body, version: version, flexible: flexible)
        if version >= 2 {
            let errorCode = try body.int16()
            try KafkaErrorCode.check(errorCode, api: "OffsetFetch")
        }
        return offsets
    }

    private static func readTopics(
        _ reader: inout KafkaProtocolReader,
        version: Int16,
        flexible: Bool
    ) throws -> [KafkaGroupOffset] {
        let topics = try reader.array(compact: flexible) { topicReader -> [KafkaGroupOffset] in
            let name = flexible ? try topicReader.compactString() : try topicReader.legacyString()
            let partitions = try topicReader.array(compact: flexible) { partitionReader -> KafkaGroupOffset in
                let index = try partitionReader.int32()
                let committed = try partitionReader.int64()
                if version >= 5 { _ = try partitionReader.int32() }   // committedLeaderEpoch
                _ = flexible
                    ? try partitionReader.nullableCompactString()
                    : try partitionReader.nullableLegacyString()      // metadata
                let errorCode = try partitionReader.int16()
                if flexible { try partitionReader.taggedFields() }
                try KafkaErrorCode.check(errorCode, api: "OffsetFetch")
                return KafkaGroupOffset(topic: name, partition: index, committedOffset: committed)
            }
            if flexible { try topicReader.taggedFields() }
            return partitions
        }
        return topics.flatMap { $0 }
    }
}
