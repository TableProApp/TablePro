import Foundation

// EWKB sets high bits for Z, M and SRID (measured on PostGIS 3.6.4); ISO WKB adds 1000, 2000 or 3000 to the type.
struct WKBCursor {
    enum ByteOrder {
        case little
        case big
    }

    struct Header {
        let order: ByteOrder
        let type: UInt32
        let hasZ: Bool
        let hasM: Bool
        let declaresSRID: Bool
        // Nil for zero too: PostGIS writes no SRID= for it.
        let srid: Int32?

        var ordinates: Int { 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0) }
    }

    private enum Flags {
        static let srid: UInt32 = 0x2000_0000
        static let z: UInt32 = 0x8000_0000
        static let m: UInt32 = 0x4000_0000
    }

    private let bytes: [UInt8]
    private var index = 0
    var failure: SpatialReadFailure?

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { index >= bytes.count }

    var remainingCount: Int { bytes.count - index }

    static func bytes(fromHex text: String) -> [UInt8]? {
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty, utf8.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count / 2)
        var high: UInt8?
        for byte in utf8 {
            let nibble: UInt8
            switch byte {
            case 0x30 ... 0x39: nibble = byte - 0x30
            case 0x41 ... 0x46: nibble = byte - 0x41 + 10
            case 0x61 ... 0x66: nibble = byte - 0x61 + 10
            default: return nil
            }
            if let pending = high {
                out.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? out : nil
    }

    mutating func readHeader() -> Header? {
        guard let order = readByteOrder(), let raw = readUInt32(order) else { return nil }
        var type = raw & 0x0FFF_FFFF
        var hasZ = raw & Flags.z != 0
        var hasM = raw & Flags.m != 0
        if type >= 3_000 {
            type -= 3_000
            hasZ = true
            hasM = true
        } else if type >= 2_000 {
            type -= 2_000
            hasM = true
        } else if type >= 1_000 {
            type -= 1_000
            hasZ = true
        }
        var srid: Int32?
        if raw & Flags.srid != 0 {
            guard let value = readUInt32(order) else { return nil }
            srid = value == 0 ? nil : Int32(bitPattern: value)
        }
        return Header(order: order, type: type, hasZ: hasZ, hasM: hasM, declaresSRID: raw & Flags.srid != 0, srid: srid)
    }

    // Refused when the bytes left cannot hold that many elements, so a corrupt count reserves nothing.
    mutating func readCount(_ order: ByteOrder, minimumElementSize: Int) -> Int? {
        guard let count = readUInt32(order) else { return nil }
        guard Int(count) <= remainingCount / max(minimumElementSize, 1) else {
            failure = .malformed
            return nil
        }
        return Int(count)
    }

    mutating func readUInt32(_ order: ByteOrder) -> UInt32? {
        guard remainingCount >= 4 else {
            failure = .malformed
            return nil
        }
        let slice = bytes[index ..< index + 4]
        index += 4
        var value: UInt32 = 0
        if order == .little {
            for (offset, byte) in slice.enumerated() { value |= UInt32(byte) << (8 * offset) }
        } else {
            for byte in slice { value = value << 8 | UInt32(byte) }
        }
        return value
    }

    mutating func readDouble(_ order: ByteOrder) -> Double? {
        guard remainingCount >= 8 else {
            failure = .malformed
            return nil
        }
        let slice = bytes[index ..< index + 8]
        index += 8
        var bits: UInt64 = 0
        if order == .little {
            for (offset, byte) in slice.enumerated() { bits |= UInt64(byte) << (8 * offset) }
        } else {
            for byte in slice { bits = bits << 8 | UInt64(byte) }
        }
        return Double(bitPattern: bits)
    }

    private mutating func readByteOrder() -> ByteOrder? {
        guard index < bytes.count else {
            failure = .malformed
            return nil
        }
        let raw = bytes[index]
        index += 1
        switch raw {
        case 0: return .big
        case 1: return .little
        default:
            failure = .notGeometry
            return nil
        }
    }
}
