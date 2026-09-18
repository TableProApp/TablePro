//
//  RedisKeySlot.swift
//  RedisDriverPlugin
//
//  Redis Cluster hash slot assignment. Verified against CLUSTER KEYSLOT on Redis 8.10.1.
//

import Foundation

enum RedisKeySlot {
    static let slotCount = 16_384

    static func slot(for key: String) -> Int {
        slot(for: Data(key.utf8))
    }

    static func slot(for key: Data) -> Int {
        Int(crc16(hashedRegion(of: key))) & (slotCount - 1)
    }

    static func hashTag(of key: Data) -> Data? {
        guard let open = key.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        let afterOpen = key.index(after: open)
        guard let close = key[afterOpen...].firstIndex(of: UInt8(ascii: "}")) else { return nil }
        guard close > afterOpen else { return nil }
        return key[afterOpen ..< close]
    }

    static func slotsAreEqual(for keys: [Data]) -> Bool {
        guard let first = keys.first else { return true }
        let reference = slot(for: first)
        return keys.allSatisfy { slot(for: $0) == reference }
    }

    private static func hashedRegion(of key: Data) -> Data {
        hashTag(of: key) ?? key
    }

    /// CRC16-XMODEM: polynomial 0x1021, zero init, not reflected, no final xor.
    private static func crc16(_ bytes: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
