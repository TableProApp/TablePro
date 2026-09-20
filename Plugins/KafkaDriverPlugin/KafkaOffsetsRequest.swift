import Foundation

struct KafkaPartitionOffsets: Sendable {
    let partition: Int32
    let earliest: Int64
    let latest: Int64

    var messageCount: Int64 { max(0, latest - earliest) }
}

enum KafkaOffsetsRequest {
    /// ListOffsets' timestamp field is overloaded: -2 asks for the earliest offset, -1 for the
    /// next offset to be written, and any other value asks for the first offset at or after
    /// that wall-clock time, which is what makes "seek to a time" possible at all.
    static let earliestTimestamp: Int64 = -2
    static let latestTimestamp: Int64 = -1

    static let api = "ListOffsets"

    /// Each partition's offset, asked of each partition's leader.
    ///
    /// The routing is the whole point. Only the leader of a partition can answer for it: every
    /// other broker replies NOT_LEADER_OR_FOLLOWER for that partition, inside an otherwise
    /// successful response, and forwards nothing. Sending one request carrying every partition
    /// to the bootstrap broker therefore worked on a single-broker cluster and failed on every
    /// other one, which is #2993.
    static func listOffsets(
        topic: String,
        partitions: [Int32],
        timestamp: Int64,
        cluster: KafkaCluster
    ) async throws -> [Int32: Int64] {
        guard !partitions.isEmpty else { return [:] }
        let outcomes = try await cluster.withLeaders(
            topic: topic,
            partitions: partitions
        ) { connection, slice in
            try await send(topic: topic, partitions: slice, timestamp: timestamp, on: connection)
        }
        return try KafkaPartitionOutcome.requireAll(
            outcomes,
            topic: topic,
            api: api,
            routing: await cluster.routing
        )
    }

    /// The earliest and latest offset of every partition, which together give the topic's
    /// message count and the anchors every browse mode seeks from.
    ///
    /// A partition with no answer is an error rather than a zero. It used to read
    /// `earliest[partition] ?? 0`, which was unreachable while one request either answered for
    /// every partition or threw; once the request is split per leader, one leader failing would
    /// have turned its partitions into real-looking empty ones, under-counting the sidebar and
    /// sending a tail scan back to the start of the log.
    static func bounds(topic: String, partitions: [Int32], cluster: KafkaCluster) async throws -> [KafkaPartitionOffsets] {
        guard !partitions.isEmpty else { return [] }
        // Sequential, not concurrent. Both calls ask about the same partitions, so they route to
        // the same leaders, and overlapping them would put two requests on each of those
        // connections at once.
        let earliest = try await listOffsets(
            topic: topic,
            partitions: partitions,
            timestamp: earliestTimestamp,
            cluster: cluster
        )
        let latest = try await listOffsets(
            topic: topic,
            partitions: partitions,
            timestamp: latestTimestamp,
            cluster: cluster
        )
        let missing = partitions.filter { earliest[$0] == nil || latest[$0] == nil }
        guard missing.isEmpty else {
            throw KafkaError.partitionsUnanswered(topic: topic, partitions: missing, api: api)
        }
        return partitions.sorted().map { partition in
            KafkaPartitionOffsets(
                partition: partition,
                earliest: earliest[partition] ?? 0,
                latest: latest[partition] ?? 0
            )
        }
    }

    /// One ListOffsets to one broker, for the partitions that broker leads.
    ///
    /// Every partition's error code is carried back rather than thrown, because the reply is a
    /// list of per-partition answers and throwing on the first bad one discards the good ones
    /// parsed beside it.
    private static func send(
        topic: String,
        partitions: [Int32],
        timestamp: Int64,
        on connection: KafkaConnection
    ) async throws -> [Int32: KafkaPartitionOutcome<Int64>] {
        let version = try await connection.negotiatedVersion(for: .listOffsets)
        let flexible = KafkaApiKey.listOffsets.isFlexible(version: version)

        let request = KafkaRequest(api: .listOffsets, version: version) { writer, _ in
            writer.int32(-1)                                   // replicaId: -1 means "a consumer"
            // read_committed, matching Fetch. Reading uncommitted here returns the high
            // watermark while the fetch stops at the last stable offset, so an open
            // transaction makes every page look permanently short of its own end.
            if version >= 2 { writer.int8(1) }                 // isolationLevel
            if flexible {
                writer.compactArrayCount(1)
                writer.compactString(topic)
                writer.compactArrayCount(partitions.count)
            } else {
                writer.legacyArrayCount(1)
                writer.legacyString(topic)
                writer.legacyArrayCount(partitions.count)
            }
            for partition in partitions {
                writer.int32(partition)
                if version >= 4 { writer.int32(-1) }           // currentLeaderEpoch
                writer.int64(timestamp)
                if version == 0 { writer.int32(1) }            // maxNumOffsets, v0 only
                if flexible { writer.emptyTaggedFields() }
            }
            if flexible {
                writer.emptyTaggedFields()
                writer.emptyTaggedFields()
            }
        }

        var body = try await connection.send(request)
        if version >= 2 { _ = try body.int32() }               // throttleTimeMs

        let topics = try body.array(compact: flexible) { reader -> [(Int32, Int64, Int16)] in
            _ = flexible ? try reader.compactString() : try reader.legacyString()
            let partitions = try reader.array(compact: flexible) { partitionReader -> (Int32, Int64, Int16) in
                let index = try partitionReader.int32()
                let errorCode = try partitionReader.int16()
                var offset: Int64 = -1
                if version == 0 {
                    let legacy = try partitionReader.array(compact: false) { try $0.int64() }
                    offset = legacy.first ?? -1
                } else {
                    _ = try partitionReader.int64()            // timestamp
                    offset = try partitionReader.int64()
                    if version >= 4 { _ = try partitionReader.int32() }  // leaderEpoch
                }
                if flexible { try partitionReader.taggedFields() }
                return (index, offset, errorCode)
            }
            // The topic struct closes with its own tag buffer, after its partitions.
            if flexible { try reader.taggedFields() }
            return partitions
        }

        var outcomes: [Int32: KafkaPartitionOutcome<Int64>] = [:]
        for entry in topics.flatMap({ $0 }) {
            outcomes[entry.0] = entry.2 == KafkaErrorCode.none ? .value(entry.1) : .rejected(code: entry.2)
        }
        return outcomes
    }
}
