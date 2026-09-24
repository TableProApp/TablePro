import Foundation

public struct JSONKeyTable: Sendable, Equatable {
    private static let emptySlot: Int32 = -1

    private var storage: [UInt8] = []
    private var offsets: [Int] = [0]
    private var hashes: [UInt64] = []
    private var slots: [Int32] = Array(repeating: JSONKeyTable.emptySlot, count: 16)

    public init() {}

    public var count: Int { hashes.count }

    public var names: [String] {
        (0..<count).map(name(of:))
    }

    public func name(of column: Int) -> String {
        storage.withUnsafeBufferPointer { buffer in
            JSONText.lossyString(UnsafeBufferPointer(rebasing: buffer[offsets[column]..<offsets[column + 1]]))
        }
    }

    public func column(named name: String) -> Int? {
        var copy = name
        return copy.withUTF8 { column(for: $0) }
    }

    @inline(__always)
    internal func matches(_ column: Int, _ key: UnsafeBufferPointer<UInt8>) -> Bool {
        let start = offsets[column]
        let length = offsets[column + 1] - start
        guard length == key.count else { return false }
        guard length > 0, let keyBase = key.baseAddress else { return true }
        return storage.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return JSONWord.equal(base + start, keyBase, count: length)
        }
    }

    public func column(for key: UnsafeBufferPointer<UInt8>) -> Int? {
        let hash = Self.hash(key)
        let mask = slots.count - 1
        var position = Int(truncatingIfNeeded: hash) & mask
        while true {
            let slot = slots[position]
            if slot == Self.emptySlot { return nil }
            let column = Int(slot)
            if hashes[column] == hash, matches(column, key) { return column }
            position = (position + 1) & mask
        }
    }

    @discardableResult
    internal mutating func insert(_ key: UnsafeBufferPointer<UInt8>) -> Int {
        let hash = Self.hash(key)
        let mask = slots.count - 1
        var position = Int(truncatingIfNeeded: hash) & mask
        while true {
            let slot = slots[position]
            if slot == Self.emptySlot { break }
            let column = Int(slot)
            if hashes[column] == hash, matches(column, key) { return column }
            position = (position + 1) & mask
        }
        let column = count
        storage.append(contentsOf: key)
        offsets.append(storage.count)
        hashes.append(hash)
        slots[position] = Int32(truncatingIfNeeded: column)
        if count * 2 > slots.count {
            grow()
        }
        return column
    }

    private mutating func grow() {
        let capacity = slots.count * 2
        var grown = Array(repeating: Self.emptySlot, count: capacity)
        let mask = capacity - 1
        for (column, hash) in hashes.enumerated() {
            var position = Int(truncatingIfNeeded: hash) & mask
            while grown[position] != Self.emptySlot {
                position = (position + 1) & mask
            }
            grown[position] = Int32(truncatingIfNeeded: column)
        }
        slots = grown
    }

    private static func hash(_ key: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 ^ UInt64(key.count)
        for byte in key {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash ^ (hash >> 29)
    }
}

internal struct JSONKeyPredictor {
    private var expected: [Int] = []

    @inline(__always)
    mutating func column(
        for key: UnsafeBufferPointer<UInt8>,
        ordinal: Int,
        in table: JSONKeyTable
    ) -> Int? {
        if ordinal < expected.count {
            let predicted = expected[ordinal]
            if predicted >= 0, table.matches(predicted, key) { return predicted }
        }
        let resolved = table.column(for: key)
        remember(resolved ?? -1, at: ordinal)
        return resolved
    }

    @inline(__always)
    mutating func register(_ key: UnsafeBufferPointer<UInt8>, ordinal: Int, in table: inout JSONKeyTable) {
        if ordinal < expected.count {
            let predicted = expected[ordinal]
            if predicted >= 0, table.matches(predicted, key) { return }
        }
        remember(table.insert(key), at: ordinal)
    }

    private mutating func remember(_ column: Int, at ordinal: Int) {
        if ordinal < expected.count {
            expected[ordinal] = column
            return
        }
        while expected.count < ordinal {
            expected.append(-1)
        }
        expected.append(column)
    }
}
