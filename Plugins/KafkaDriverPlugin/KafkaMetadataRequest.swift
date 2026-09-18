import Foundation

enum KafkaMetadataRequest {
    /// Metadata, which names the brokers, the topics and each partition's leader.
    ///
    /// Two version-dependent details decide whether this parses at all. `topics` is a NULLABLE
    /// array and null means "every topic", but in compact encoding null is uvarint 0, not the
    /// legacy -1: writing `0xff` here sets the varint continuation bit, the broker keeps
    /// consuming the bytes that follow, and it then closes the socket without an error. And
    /// v11 REMOVED `includeClusterAuthorizedOperations`, so v11 and v12 carry two trailing
    /// booleans where v8 to v10 carry three.
    static func fetch(topics: [String]?, on connection: KafkaConnection) async throws -> KafkaClusterMetadata {
        let version = try await connection.negotiatedVersion(for: .metadata)
        let flexible = KafkaApiKey.metadata.isFlexible(version: version)

        let request = KafkaRequest(api: .metadata, version: version) { writer, _ in
            if let topics {
                if flexible {
                    writer.compactArrayCount(topics.count)
                } else {
                    writer.legacyArrayCount(topics.count)
                }
                for topic in topics {
                    if version >= 10 { writer.uuid(.zero) }
                    if flexible {
                        writer.compactString(topic)
                        writer.emptyTaggedFields()
                    } else {
                        writer.legacyString(topic)
                    }
                }
            } else if flexible {
                writer.compactArrayCount(nil)
            } else {
                writer.legacyArrayCount(nil)
            }

            if version >= 4 { writer.boolean(false) }              // allowAutoTopicCreation
            if version >= 8, version <= 10 { writer.boolean(false) }  // includeClusterAuthorizedOperations
            if version >= 8 { writer.boolean(false) }              // includeTopicAuthorizedOperations
            if flexible { writer.emptyTaggedFields() }
        }

        var body = try await connection.send(request)
        if version >= 3 { _ = try body.int32() }                   // throttleTimeMs

        let brokers = try body.array(compact: flexible) { reader -> KafkaBroker in
            let nodeId = try reader.int32()
            let host = flexible ? try reader.compactString() : try reader.legacyString()
            let port = try reader.int32()
            var rack: String?
            if version >= 1 {
                rack = flexible ? try reader.nullableCompactString() : try reader.nullableLegacyString()
            }
            if flexible { try reader.taggedFields() }
            return KafkaBroker(nodeId: nodeId, endpoint: KafkaEndpoint(host: host, port: Int(port)), rack: rack)
        }

        var clusterId: String?
        if version >= 2 {
            clusterId = flexible ? try body.nullableCompactString() : try body.nullableLegacyString()
        }
        var controllerId: Int32 = -1
        if version >= 1 { controllerId = try body.int32() }

        let topicList = try body.array(compact: flexible) { reader -> KafkaTopic in
            let errorCode = try reader.int16()
            let name = flexible ? try reader.nullableCompactString() : try reader.nullableLegacyString()
            var topicId = KafkaUUID.zero
            if version >= 10 { topicId = try reader.uuid() }
            var isInternal = false
            if version >= 1 { isInternal = try reader.boolean() }

            let partitions = try reader.array(compact: flexible) { partitionReader -> KafkaPartition in
                let partitionError = try partitionReader.int16()
                let index = try partitionReader.int32()
                let leader = try partitionReader.int32()
                if version >= 7 { _ = try partitionReader.int32() }   // leaderEpoch
                let replicas = try partitionReader.array(compact: flexible) { try $0.int32() }
                let isr = try partitionReader.array(compact: flexible) { try $0.int32() }
                if version >= 5 {
                    _ = try partitionReader.array(compact: flexible) { try $0.int32() }  // offlineReplicas
                }
                if flexible { try partitionReader.taggedFields() }
                return KafkaPartition(
                    index: index,
                    leader: leader,
                    replicas: replicas,
                    inSyncReplicas: isr,
                    errorCode: partitionError
                )
            }
            if version >= 8 { _ = try reader.int32() }               // topicAuthorizedOperations
            if flexible { try reader.taggedFields() }
            return KafkaTopic(
                name: name ?? "",
                topicId: topicId,
                isInternal: isInternal,
                partitions: partitions,
                errorCode: errorCode
            )
        }

        return KafkaClusterMetadata(
            brokers: brokers,
            controllerId: controllerId,
            clusterId: clusterId,
            topics: topicList
        )
    }
}
