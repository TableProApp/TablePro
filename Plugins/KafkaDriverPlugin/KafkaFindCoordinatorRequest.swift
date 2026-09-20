import Foundation

/// Asks any broker which broker coordinates a consumer group.
///
/// Every broker answers this one, which is what makes it the entry point to coordinator
/// routing: the client has no way to work out the coordinator itself, because it is the broker
/// owning the `__consumer_offsets` partition the group id hashes to, and the partition count of
/// that topic is not something a client is told.
///
/// The response field order changed at v4 and it is not guessable from the versions either side
/// of it. Up to v3 the body opens with the error, then names the node; v4 (KIP-699) made the
/// request batched and moved the error to the END of each coordinator entry, after the address.
/// Reading v4 in the v3 order parses a node id out of the error code and a port out of the
/// host's length prefix, which yields a plausible broker id rather than a parse failure. Both
/// orders below were measured against a live Kafka 4.3.1 broker.
enum KafkaFindCoordinatorRequest {
    /// `keyType` 0 is a consumer group. 1 is a transaction coordinator, which this driver does
    /// not use: it neither produces transactionally nor reads transaction state.
    private static let groupKeyType: Int8 = 0

    static func coordinator(forGroup group: String, on connection: KafkaConnection) async throws -> Int32 {
        let version = try await connection.negotiatedVersion(for: .findCoordinator)
        let flexible = KafkaApiKey.findCoordinator.isFlexible(version: version)

        let request = KafkaRequest(api: .findCoordinator, version: version) { writer, _ in
            if version >= 4 {
                writer.int8(groupKeyType)
                writer.compactArrayCount(1)
                writer.compactString(group)
                writer.emptyTaggedFields()
                return
            }
            if flexible {
                writer.compactString(group)
            } else {
                writer.legacyString(group)
            }
            if version >= 1 { writer.int8(groupKeyType) }
            if flexible { writer.emptyTaggedFields() }
        }

        var body = try await connection.send(request)
        if version >= 1 { _ = try body.int32() }                   // throttleTimeMs

        if version >= 4 {
            let coordinators = try body.array(compact: true) { reader -> (String, Int32, Int16) in
                let key = try reader.compactString()
                let nodeId = try reader.int32()
                _ = try reader.compactString()                     // host
                _ = try reader.int32()                             // port
                let errorCode = try reader.int16()
                _ = try reader.nullableCompactString()             // errorMessage
                try reader.taggedFields()
                return (key, nodeId, errorCode)
            }
            guard let entry = coordinators.first(where: { $0.0 == group }) ?? coordinators.first else {
                throw KafkaError.malformedResponse(
                    String(localized: "The broker answered a coordinator lookup with no coordinator.")
                )
            }
            try KafkaErrorCode.check(entry.2, api: KafkaApiKey.findCoordinator.name)
            return entry.1
        }

        let errorCode = try body.int16()
        if version >= 1 {
            _ = flexible ? try body.nullableCompactString() : try body.nullableLegacyString()
        }
        try KafkaErrorCode.check(errorCode, api: KafkaApiKey.findCoordinator.name)
        let nodeId = try body.int32()
        _ = flexible ? try body.compactString() : try body.legacyString()   // host
        _ = try body.int32()                                                // port
        if flexible { try body.taggedFields() }
        return nodeId
    }
}
