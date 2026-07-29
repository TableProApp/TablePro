import Foundation

enum HexBytes {
    static func decode(_ hex: String) -> [UInt8] {
        let clean = hex.unicodeScalars.filter { $0 != " " && $0 != "\n" && $0 != "\t" }
        let chars = Array(String.UnicodeScalarView(clean))
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index + 1 < chars.count {
            let pair = String(chars[index]) + String(chars[index + 1])
            bytes.append(UInt8(pair, radix: 16) ?? 0)
            index += 2
        }
        return bytes
    }
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func raw(_ data: [UInt8]) { bytes.append(contentsOf: data) }

    mutating func zeros(_ count: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: count)) }

    mutating func fixedString(_ text: String, length: Int, pad: UInt8 = 0x20) {
        var encoded = Array(text.utf8.prefix(length))
        if encoded.count < length {
            encoded.append(contentsOf: [UInt8](repeating: pad, count: length - encoded.count))
        }
        bytes.append(contentsOf: encoded)
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw TeradataWireError.truncated("u8") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw TeradataWireError.truncated("u16") }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw TeradataWireError.truncated("u32") }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard remaining >= count else { throw TeradataWireError.truncated("take(\(count))") }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw TeradataWireError.truncated("skip(\(count))") }
        offset += count
    }
}
