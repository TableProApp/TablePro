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

    static func listOffsets(
        topic: String,
        partitions: [Int32],
        timestamp: Int64,
        cluster: KafkaCluster
    ) async throws -> [Int32: Int64] {
        guard !partitions.isEmpty else { return [:] }
        let connection = try await cluster.controlConnection()
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

        var offsets: [Int32: Int64] = [:]
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

        for entry in topics.flatMap({ $0 }) {
            try KafkaErrorCode.check(entry.2, api: "ListOffsets")
            offsets[entry.0] = entry.1
        }
        return offsets
    }

    /// The earliest and latest offset of every partition, which together give the topic's
    /// message count and the anchors every browse mode seeks from.
    static func bounds(topic: String, partitions: [Int32], cluster: KafkaCluster) async throws -> [KafkaPartitionOffsets] {
        // Sequential, not concurrent. Both calls land on the same KafkaConnection, which holds
        // exactly one in-flight request: overlapping them makes the second overwrite the
        // first's continuation, so the first never resumes and the browse hangs.
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
        return partitions.sorted().map { partition in
            KafkaPartitionOffsets(
                partition: partition,
                earliest: earliest[partition] ?? 0,
                latest: latest[partition] ?? 0
            )
        }
    }
}
