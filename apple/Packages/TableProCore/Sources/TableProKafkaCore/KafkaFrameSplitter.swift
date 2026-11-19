import Foundation

// Splits the stream into replies, each a 4-byte big-endian length and that many bytes. A reply longer than its request
// allows is refused at its length, before any of its bytes are kept, and then skipped as they arrive so the stream stays
// in step for the next reply.
public struct KafkaFrameSplitter: Sendable {
    // A corrupt or non-Kafka peer can announce a 2 GB frame.
    public static let maximumFrameLength = 256 * 1_024 * 1_024

    public enum Step: Equatable, Sendable {
        case needMoreData
        // Drop the length, then the next `length` bytes are the reply.
        case reply(length: Int)
        // Drop the length; the reply's bytes are skipped as they come.
        case refuse(length: Int)
        // Drop this many bytes of a refused reply.
        case skip(Int)
    }

    private var skipping = 0

    public init() {}

    public mutating func next(readable: Int, announcedLength: Int32?, limit: Int) throws -> Step {
        if skipping > 0 {
            guard readable > 0 else { return .needMoreData }
            let count = min(skipping, readable)
            skipping -= count
            return .skip(count)
        }
        guard readable >= 4, let announcedLength else { return .needMoreData }
        let length = Int(announcedLength)
        guard length >= 0, length <= Self.maximumFrameLength else {
            throw KafkaError.malformedResponse(
                "the peer announced a \(length)-byte frame; this is probably not a Kafka broker"
            )
        }
        if length > limit {
            skipping = length
            return .refuse(length: length)
        }
        guard readable - 4 >= length else { return .needMoreData }
        return .reply(length: length)
    }
}
