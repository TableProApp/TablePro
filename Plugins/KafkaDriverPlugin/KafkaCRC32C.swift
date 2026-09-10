import Foundation

/// CRC-32C (Castagnoli), which is what a v2 record batch carries. macOS supplies no such
/// routine: zlib's `crc32` is the IEEE polynomial and libz has no `crc32c` entry point, so
/// this table is the portable answer and it works on both slices of the universal binary.
///
/// A read path can skip verification, but Produce cannot: a batch whose CRC does not match is
/// rejected by the broker with CORRUPT_MESSAGE.
enum KafkaCRC32C {
    private static let table: [UInt32] = {
        let polynomial: UInt32 = 0x82F6_3B78
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) == 1 ? (value >> 1) ^ polynomial : value >> 1
            }
            table[index] = value
        }
        return table
    }()

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
