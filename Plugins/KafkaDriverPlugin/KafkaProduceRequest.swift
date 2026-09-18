import Foundation

struct KafkaProduceResult: Sendable {
    let partition: Int32
    let baseOffset: Int64
}

enum KafkaProduceRequest {
    /// Appends one record. `acks = -1` waits for every in-sync replica, which is the only
    /// setting that lets this report an offset the cluster will not lose.
    private static let acksAllInSyncReplicas: Int16 = -1

    static func produce(
        topic: String,
        partition: Int32,
        key: Data?,
        value: Data?,
        headers: [KafkaRecordHeader],
        timestamp: Int64,
        cluster: KafkaCluster
    ) async throws -> KafkaProduceResult {
        let batch = KafkaRecordBatchEncoder.singleRecordBatch(
            key: key,
            value: value,
            headers: headers,
            timestamp: timestamp
        )

        return try await cluster.withLeader(of: partition, topic: topic) { connection in
            let version = try await connection.negotiatedVersion(for: .produce)
            let flexible = KafkaApiKey.produce.isFlexible(version: version)

            let request = KafkaRequest(api: .produce, version: version) { writer, _ in
                if version >= 3 {
                    if flexible {
                        writer.nullableCompactString(nil)          // transactionalId
                    } else {
                        writer.nullableLegacyString(nil)
                    }
                }
                writer.int16(acksAllInSyncReplicas)
                writer.int32(30_000)                               // timeoutMs
                if flexible {
                    writer.compactArrayCount(1)
                    writer.compactString(topic)
                    writer.compactArrayCount(1)
                } else {
                    writer.legacyArrayCount(1)
                    writer.legacyString(topic)
                    writer.legacyArrayCount(1)
                }
                writer.int32(partition)
                if flexible {
                    writer.nullableCompactBytes(batch)
                    writer.emptyTaggedFields()
                    writer.emptyTaggedFields()
                    writer.emptyTaggedFields()
                } else {
                    writer.nullableLegacyBytes(batch)
                }
            }

            var body = try await connection.send(request)
            var produced = KafkaProduceResult(partition: partition, baseOffset: -1)
            let responses = try body.array(compact: flexible) { reader -> [KafkaProduceResult] in
                _ = flexible ? try reader.compactString() : try reader.legacyString()
                let partitions = try reader.array(compact: flexible) { partitionReader -> KafkaProduceResult in
                    let index = try partitionReader.int32()
                    let errorCode = try partitionReader.int16()
                    let baseOffset = try partitionReader.int64()
                    if version >= 2 { _ = try partitionReader.int64() }   // logAppendTime
                    if version >= 5 { _ = try partitionReader.int64() }   // logStartOffset
                    if version >= 8 {
                        _ = try partitionReader.array(compact: flexible) { recordError -> Int32 in
                            let batchIndex = try recordError.int32()
                            _ = flexible
                                ? try recordError.nullableCompactString()
                                : try recordError.nullableLegacyString()
                            if flexible { try recordError.taggedFields() }
                            return batchIndex
                        }
                        _ = flexible
                            ? try partitionReader.nullableCompactString()
                            : try partitionReader.nullableLegacyString()
                    }
                    if flexible { try partitionReader.taggedFields() }
                    try KafkaErrorCode.check(errorCode, api: "Produce")
                    return KafkaProduceResult(partition: index, baseOffset: baseOffset)
                }
                if flexible { try reader.taggedFields() }
                return partitions
            }
            if let first = responses.flatMap({ $0 }).first { produced = first }
            return produced
        }
    }
}
