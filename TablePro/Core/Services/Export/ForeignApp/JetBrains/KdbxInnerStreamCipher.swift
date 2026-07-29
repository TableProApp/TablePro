//
//  KdbxInnerStreamCipher.swift
//  TablePro
//

import Foundation

protocol KdbxInnerStreamCipher {
    mutating func process(_ data: [UInt8]) -> [UInt8]
}

/// IETF ChaCha20 (RFC 8439). KeePass derives key and nonce from SHA-512 of the
/// protected-stream key: key = digest[0..<32], nonce = digest[32..<44].
struct ChaCha20Cipher: KdbxInnerStreamCipher {
    private var state: [UInt32]
    private var keyStream: [UInt8] = []
    private var offset = 0

    init(key: [UInt8], nonce: [UInt8]) {
        var initial = [UInt32](repeating: 0, count: 16)
        initial[0] = 0x6170_7865
        initial[1] = 0x3320_646e
        initial[2] = 0x7962_2d32
        initial[3] = 0x6b20_6574
        for index in 0..<8 {
            initial[4 + index] = Self.load32(key, index * 4)
        }
        initial[12] = 0
        for index in 0..<3 {
            initial[13 + index] = Self.load32(nonce, index * 4)
        }
        state = initial
    }

    mutating func process(_ data: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count)
        for index in 0..<data.count {
            if offset >= keyStream.count {
                keyStream = nextBlock()
                offset = 0
            }
            output[index] = data[index] ^ keyStream[offset]
            offset += 1
        }
        return output
    }

    private mutating func nextBlock() -> [UInt8] {
        var working = state
        for _ in 0..<10 {
            Self.quarterRound(&working, 0, 4, 8, 12)
            Self.quarterRound(&working, 1, 5, 9, 13)
            Self.quarterRound(&working, 2, 6, 10, 14)
            Self.quarterRound(&working, 3, 7, 11, 15)
            Self.quarterRound(&working, 0, 5, 10, 15)
            Self.quarterRound(&working, 1, 6, 11, 12)
            Self.quarterRound(&working, 2, 7, 8, 13)
            Self.quarterRound(&working, 3, 4, 9, 14)
        }
        var block = [UInt8](repeating: 0, count: 64)
        for index in 0..<16 {
            Self.store32(working[index] &+ state[index], &block, index * 4)
        }
        state[12] = state[12] &+ 1
        return block
    }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func load32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    private static func store32(_ value: UInt32, _ bytes: inout [UInt8], _ index: Int) {
        bytes[index] = UInt8(value & 0xff)
        bytes[index + 1] = UInt8((value >> 8) & 0xff)
        bytes[index + 2] = UInt8((value >> 16) & 0xff)
        bytes[index + 3] = UInt8((value >> 24) & 0xff)
    }
}

/// Salsa20 with the fixed KeePass nonce 0xE830094B97205D2A and key = SHA-256 of
/// the protected-stream key. Used by KDBX files written before the ChaCha20 default.
struct Salsa20Cipher: KdbxInnerStreamCipher {
    static let keePassNonce: [UInt8] = [0xe8, 0x30, 0x09, 0x4b, 0x97, 0x20, 0x5d, 0x2a]

    private var state: [UInt32]
    private var keyStream: [UInt8] = []
    private var offset = 0

    init(key: [UInt8], nonce: [UInt8]) {
        var initial = [UInt32](repeating: 0, count: 16)
        initial[0] = 0x6170_7865
        initial[5] = 0x3320_646e
        initial[10] = 0x7962_2d32
        initial[15] = 0x6b20_6574
        for index in 0..<4 {
            initial[1 + index] = Self.load32(key, index * 4)
            initial[11 + index] = Self.load32(key, 16 + index * 4)
        }
        initial[6] = Self.load32(nonce, 0)
        initial[7] = Self.load32(nonce, 4)
        initial[8] = 0
        initial[9] = 0
        state = initial
    }

    mutating func process(_ data: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count)
        for index in 0..<data.count {
            if offset >= keyStream.count {
                keyStream = nextBlock()
                offset = 0
            }
            output[index] = data[index] ^ keyStream[offset]
            offset += 1
        }
        return output
    }

    private mutating func nextBlock() -> [UInt8] {
        var working = state
        for _ in 0..<10 {
            Self.quarterRound(&working, 0, 4, 8, 12)
            Self.quarterRound(&working, 5, 9, 13, 1)
            Self.quarterRound(&working, 10, 14, 2, 6)
            Self.quarterRound(&working, 15, 3, 7, 11)
            Self.quarterRound(&working, 0, 1, 2, 3)
            Self.quarterRound(&working, 5, 6, 7, 4)
            Self.quarterRound(&working, 10, 11, 8, 9)
            Self.quarterRound(&working, 15, 12, 13, 14)
        }
        var block = [UInt8](repeating: 0, count: 64)
        for index in 0..<16 {
            Self.store32(working[index] &+ state[index], &block, index * 4)
        }
        state[8] = state[8] &+ 1
        if state[8] == 0 {
            state[9] = state[9] &+ 1
        }
        return block
    }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[b] ^= rotl(s[a] &+ s[d], 7)
        s[c] ^= rotl(s[b] &+ s[a], 9)
        s[d] ^= rotl(s[c] &+ s[b], 13)
        s[a] ^= rotl(s[d] &+ s[c], 18)
    }

    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func load32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    private static func store32(_ value: UInt32, _ bytes: inout [UInt8], _ index: Int) {
        bytes[index] = UInt8(value & 0xff)
        bytes[index + 1] = UInt8((value >> 8) & 0xff)
        bytes[index + 2] = UInt8((value >> 16) & 0xff)
        bytes[index + 3] = UInt8((value >> 24) & 0xff)
    }
}
