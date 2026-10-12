import Foundation

enum KafkaDeleteTopicsRequest {
    /// How long the broker may spend on the deletion before answering REQUEST_TIMED_OUT.
    ///
    /// The broker marks the topic for deletion and answers; the log directories go later. A
    /// timeout here therefore means "not accepted", not "half deleted".
    static let timeoutMs: Int32 = 30_000

    /// Deletes one topic, by name.
    ///
    /// Only the controller may accept this, so the request goes to the broker Metadata names as
    /// controller rather than to whichever broker the client happens to hold. On a single-broker
    /// cluster those are the same connection; on a real one they are not, and sending it anywhere
    /// else answers NOT_CONTROLLER.
    ///
    /// Capped at v5 deliberately: v6 addresses topics by 16-byte UUID instead of by name, which is
    /// a different request shape rather than a bigger one, the same line `KafkaApiKey` draws for
    /// Fetch and Metadata.
    static func deleteTopic(_ topic: String, cluster: KafkaCluster) async throws {
        let connection = try await cluster.controllerConnection()
        let version = try await connection.negotiatedVersion(for: .deleteTopics)
        let flexible = KafkaApiKey.deleteTopics.isFlexible(version: version)

        let request = KafkaRequest(api: .deleteTopics, version: version) { writer, _ in
            if flexible {
                /// v4 and v5 still name the topic, as a compact string inside a compact array.
                writer.compactArrayCount(1)
                writer.compactString(topic)
            } else {
                writer.legacyArrayCount(1)
                writer.legacyString(topic)
            }
            writer.int32(timeoutMs)
            if flexible { writer.emptyTaggedFields() }
        }

        var body = try await connection.send(request)
        if version >= 1 { _ = try body.int32() }               // throttleTimeMs

        let results = try body.array(compact: flexible) { reader -> Int16 in
            _ = flexible ? try reader.nullableCompactString() : try reader.nullableLegacyString()
            let errorCode = try reader.int16()
            /// v5 added a broker-supplied message. It is read so the reader stays in step with the
            /// wire, and discarded: `KafkaErrorCode.describe` is the app's own wording.
            if version >= 5 {
                _ = flexible ? try reader.nullableCompactString() : try reader.nullableLegacyString()
            }
            if flexible { try reader.taggedFields() }
            return errorCode
        }
        if flexible { try body.taggedFields() }

        guard let errorCode = results.first else {
            throw KafkaError.malformedResponse(
                String(localized: "The broker answered a topic deletion with no result.")
            )
        }
        guard errorCode == KafkaErrorCode.none else {
            throw KafkaError.broker(code: errorCode, api: KafkaApiKey.deleteTopics.name)
        }
    }
}
