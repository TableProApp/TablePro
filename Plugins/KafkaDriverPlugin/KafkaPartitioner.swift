import Foundation

/// Kafka's default key partitioner.
///
/// Matching it matters: a message produced from here with a key must land in the same
/// partition as every other message with that key, or the ordering guarantee that keyed
/// messages exist for is broken for that key. Kafka uses murmur2 with seed 0x9747b28c and
/// masks the sign bit, and that exact combination is what the Java client computes.
enum KafkaPartitioner {
    static func partition(forKey key: Data, count: Int) -> Int32 {
        guard count > 0 else { return 0 }
        let hash = murmur2(key) & 0x7FFF_FFFF
        return Int32(hash % UInt32(count))
    }

    static func murmur2(_ data: Data) -> UInt32 {
        let seed: UInt32 = 0x9747_B28C
        let multiplier: UInt32 = 0x5BD1_E995
        let rotation: UInt32 = 24

        let length = data.count
        var hash = seed ^ UInt32(truncatingIfNeeded: length)
        let bytes = [UInt8](data)
        let blockCount = length / 4

        for block in 0 ..< blockCount {
            let index = block * 4
            var chunk = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            chunk = chunk &* multiplier
            chunk ^= chunk >> rotation
            chunk = chunk &* multiplier
            hash = hash &* multiplier
            hash ^= chunk
        }

        let remainder = length % 4
        let tail = blockCount * 4
        if remainder >= 3 { hash ^= UInt32(bytes[tail + 2]) << 16 }
        if remainder >= 2 { hash ^= UInt32(bytes[tail + 1]) << 8 }
        if remainder >= 1 {
            hash ^= UInt32(bytes[tail])
            hash = hash &* multiplier
        }

        hash ^= hash >> 13
        hash = hash &* multiplier
        hash ^= hash >> 15
        return hash
    }
}
