import Foundation

/// One Kafka request: an API key, the negotiated version, and a body encoder that is handed a
/// writer already told whether this version is flexible.
struct KafkaRequest {
    let api: KafkaApiKey
    let version: Int16
    let encodeBody: (inout KafkaProtocolWriter, Bool) -> Void

    var isFlexible: Bool { api.isFlexible(version: version) }

    /// Frames the request for the wire: a 4-byte length, then the header, then the body.
    ///
    /// Two header details are load-bearing and neither is guessable from the surrounding
    /// encoding. `client_id` is declared `flexibleVersions: none`, so it stays a legacy
    /// int16-length string even inside a flexible header. And the empty tagged-field buffer
    /// that closes a flexible header is mandatory: omitting it shifts the whole body, and the
    /// broker answers by closing the socket rather than by reporting an error.
    func framed(correlationId: Int32, clientId: String) -> Data {
        var writer = KafkaProtocolWriter()
        writer.int16(api.rawValue)
        writer.int16(version)
        writer.int32(correlationId)
        writer.nullableLegacyString(clientId)
        if isFlexible {
            writer.emptyTaggedFields()
        }
        encodeBody(&writer, isFlexible)

        var framed = KafkaProtocolWriter()
        framed.int32(Int32(writer.count))
        framed.raw(writer.bytes)
        return framed.data
    }
}

enum KafkaResponseHeader {
    /// Strips the response header and returns a reader positioned at the body.
    ///
    /// ApiVersions is a documented special case: its response ALWAYS uses a v0 header with no
    /// tagged fields, at every version, because the client has to be able to parse the reply
    /// that tells it which versions exist. Kafka's own message generator hard-codes this
    /// (`if (type.equals("response") && apiKey == 18)`, KIP-511). Reading a tagged-field
    /// buffer here consumes the first byte of the error code and shifts everything after it,
    /// which surfaces as a plausible but wrong error code rather than as a parse failure.
    static func strip(_ data: Data, api: KafkaApiKey, version: Int16) throws -> (correlationId: Int32, body: KafkaProtocolReader) {
        var reader = KafkaProtocolReader(data)
        let correlationId = try reader.int32()
        if api != .apiVersions, api.isFlexible(version: version) {
            try reader.taggedFields()
        }
        return (correlationId, reader)
    }
}
