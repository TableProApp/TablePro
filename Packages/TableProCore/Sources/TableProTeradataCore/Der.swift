import Foundation

enum Der {
    static let objectIdentifierTag: UInt8 = 0x06

    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var value = length
        var lengthBytes: [UInt8] = []
        while value > 0 {
            lengthBytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(lengthBytes.count)] + lengthBytes
    }

    static func encodeTLV(tag: UInt8, value: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(value.count) + value
    }

    static func encodeObjectIdentifier(_ dotted: String) throws -> [UInt8] {
        let parts = dotted.split(separator: ".").map { Int($0) ?? -1 }
        guard parts.count >= 2, !parts.contains(where: { $0 < 0 }) else {
            throw TeradataWireError.malformed("invalid OID \(dotted)")
        }
        var content: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for component in parts.dropFirst(2) {
            content.append(contentsOf: base128(component))
        }
        return encodeTLV(tag: objectIdentifierTag, value: content)
    }

    static func decodeObjectIdentifier(_ bytes: [UInt8]) throws -> String {
        var reader = ByteReader(bytes)
        guard try reader.u8() == objectIdentifierTag else { throw TeradataWireError.malformed("expected OID tag") }
        let length = try decodeLength(&reader)
        let content = try reader.take(length)
        guard let first = content.first else { throw TeradataWireError.malformed("empty OID") }
        var components = [Int(first) / 40, Int(first) % 40]
        var accumulator = 0
        for byte in content.dropFirst() {
            accumulator = (accumulator << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                components.append(accumulator)
                accumulator = 0
            }
        }
        return components.map(String.init).joined(separator: ".")
    }

    static func decodeLength(_ reader: inout ByteReader) throws -> Int {
        let first = try reader.u8()
        if first < 0x80 { return Int(first) }
        let count = Int(first & 0x7F)
        var length = 0
        for _ in 0..<count { length = (length << 8) | Int(try reader.u8()) }
        return length
    }

    private static func base128(_ value: Int) -> [UInt8] {
        guard value >= 0x80 else { return [UInt8(value)] }
        var chunks: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            chunks.insert(UInt8(remaining & 0x7F), at: 0)
            remaining >>= 7
        }
        for index in 0..<(chunks.count - 1) { chunks[index] |= 0x80 }
        return chunks
    }
}
