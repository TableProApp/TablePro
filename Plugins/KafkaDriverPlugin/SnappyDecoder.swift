import Foundation

/// Snappy block-format decompression. macOS ships no snappy at any layer, and Kafka's Java
/// producer still writes it, so a topic produced by a Java service is unreadable without this.
///
/// The format is small: a varint of the decompressed length, then a run of elements that are
/// either a literal or a back-reference copy. Only decompression is implemented, because this
/// client never produces a compressed batch.
enum SnappyDecoder {
    static func decode(_ input: [UInt8]) throws -> [UInt8] {
        var cursor = 0
        let expectedLength = try varint(input, &cursor)
        guard expectedLength <= 512 * 1024 * 1024 else {
            throw KafkaError.decompressionFailed(codec: "snappy", reason: "declared length is implausible")
        }

        var output = [UInt8]()
        output.reserveCapacity(expectedLength)

        while cursor < input.count {
            let tag = input[cursor]
            cursor += 1
            switch tag & 0x03 {
            case 0:
                try literal(tag, input, &cursor, &output)
            case 1:
                // 1-byte offset copy: 3 length bits (+4) and the offset's high 3 bits.
                guard cursor < input.count else {
                    throw KafkaError.decompressionFailed(codec: "snappy", reason: "copy ran past the input")
                }
                let length = 4 + Int((tag >> 2) & 0x07)
                let offset = Int(tag & 0xE0) << 3 | Int(input[cursor])
                cursor += 1
                try copy(offset: offset, length: length, into: &output)
            case 2:
                try copyWithOffset(width: 2, tag: tag, input: input, cursor: &cursor, output: &output)
            default:
                try copyWithOffset(width: 4, tag: tag, input: input, cursor: &cursor, output: &output)
            }
        }

        guard output.count == expectedLength else {
            throw KafkaError.decompressionFailed(
                codec: "snappy",
                reason: "decoded \(output.count) bytes, the block declared \(expectedLength)"
            )
        }
        return output
    }

    private static func literal(
        _ tag: UInt8,
        _ input: [UInt8],
        _ cursor: inout Int,
        _ output: inout [UInt8]
    ) throws {
        var length = Int(tag >> 2)
        if length >= 60 {
            let extraBytes = length - 59
            guard cursor + extraBytes <= input.count else {
                throw KafkaError.decompressionFailed(codec: "snappy", reason: "literal length ran past the input")
            }
            var value = 0
            for index in 0 ..< extraBytes {
                value |= Int(input[cursor + index]) << (8 * index)
            }
            cursor += extraBytes
            length = value
        }
        length += 1
        guard length >= 0, cursor + length <= input.count else {
            throw KafkaError.decompressionFailed(codec: "snappy", reason: "literal ran past the input")
        }
        output.append(contentsOf: input[cursor ..< cursor + length])
        cursor += length
    }

    private static func copyWithOffset(
        width: Int,
        tag: UInt8,
        input: [UInt8],
        cursor: inout Int,
        output: inout [UInt8]
    ) throws {
        guard cursor + width <= input.count else {
            throw KafkaError.decompressionFailed(codec: "snappy", reason: "copy offset ran past the input")
        }
        var offset = 0
        for index in 0 ..< width {
            offset |= Int(input[cursor + index]) << (8 * index)
        }
        cursor += width
        try copy(offset: offset, length: Int(tag >> 2) + 1, into: &output)
    }

    /// A snappy copy may overlap its own output, so it has to be byte-at-a-time: the source
    /// range can extend into bytes this very loop is appending. A bulk copy silently produces
    /// the wrong result for a run-length pattern.
    private static func copy(offset: Int, length: Int, into output: inout [UInt8]) throws {
        guard offset > 0, offset <= output.count else {
            throw KafkaError.decompressionFailed(codec: "snappy", reason: "copy offset \(offset) is out of range")
        }
        var source = output.count - offset
        for _ in 0 ..< length {
            output.append(output[source])
            source += 1
        }
    }

    private static func varint(_ input: [UInt8], _ cursor: inout Int) throws -> Int {
        var result = 0
        var shift = 0
        while true {
            guard cursor < input.count else {
                throw KafkaError.decompressionFailed(codec: "snappy", reason: "length varint is truncated")
            }
            let byte = input[cursor]
            cursor += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift <= 28 else {
                throw KafkaError.decompressionFailed(codec: "snappy", reason: "length varint is too long")
            }
        }
    }
}
