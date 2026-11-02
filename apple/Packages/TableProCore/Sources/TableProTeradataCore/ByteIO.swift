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
