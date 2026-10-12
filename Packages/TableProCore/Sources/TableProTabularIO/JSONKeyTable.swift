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
        withLookup { JSONText.lossyString($0.key(of: column)) }
    }

    public func column(named name: String) -> Int? {
        withLookup { $0.column(named: name) }
    }

    public func column(for key: UnsafeBufferPointer<UInt8>) -> Int? {
        withLookup { $0.column(for: key) }
    }

    @inline(__always)
    internal func matches(_ column: Int, _ key: UnsafeBufferPointer<UInt8>) -> Bool {
        storage.withUnsafeBufferPointer { storage in
            offsets.withUnsafeBufferPointer { offsets in
                JSONKeyLookup.matches(column, key, storage: storage, offsets: offsets)
            }
        }
    }

    internal func withLookup<Result>(_ body: (JSONKeyLookup) throws -> Result) rethrows -> Result {
        try storage.withUnsafeBufferPointer { storage in
            try offsets.withUnsafeBufferPointer { offsets in
                try hashes.withUnsafeBufferPointer { hashes in
                    try slots.withUnsafeBufferPointer { slots in
                        try body(JSONKeyLookup(storage: storage, offsets: offsets, hashes: hashes, slots: slots))
                    }
                }
            }
        }
    }

    @discardableResult
    internal mutating func insert(_ key: UnsafeBufferPointer<UInt8>) -> Int {
        if let existing = column(for: key) { return existing }
        let hash = JSONKeyLookup.hash(key)
        let column = count
        storage.append(contentsOf: key)
        offsets.append(storage.count)
        hashes.append(hash)
        if (count * 2) > slots.count {
            rebuildSlots(capacity: slots.count * 2)
        } else {
            place(column, hash: hash)
        }
        return column
    }

    private mutating func rebuildSlots(capacity: Int) {
        slots = Array(repeating: Self.emptySlot, count: capacity)
        for (column, hash) in hashes.enumerated() {
            place(column, hash: hash)
        }
    }

    private mutating func place(_ column: Int, hash: UInt64) {
        let mask = slots.count - 1
        var position = Int(truncatingIfNeeded: hash) & mask
        while slots[position] != Self.emptySlot {
            position = (position + 1) & mask
        }
        slots[position] = Int32(truncatingIfNeeded: column)
    }
}

internal struct JSONKeyLookup {
    private let storage: UnsafeBufferPointer<UInt8>
    private let offsets: UnsafeBufferPointer<Int>
    private let hashes: UnsafeBufferPointer<UInt64>
    private let slots: UnsafeBufferPointer<Int32>

    init(
        storage: UnsafeBufferPointer<UInt8>,
        offsets: UnsafeBufferPointer<Int>,
        hashes: UnsafeBufferPointer<UInt64>,
        slots: UnsafeBufferPointer<Int32>
    ) {
        self.storage = storage
        self.offsets = offsets
        self.hashes = hashes
        self.slots = slots
    }

    static func hash(_ key: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 ^ UInt64(key.count)
        for byte in key {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash ^ (hash >> 29)
    }

    var count: Int { hashes.count }

    func column(named name: String) -> Int? {
        var copy = name
        return copy.withUTF8 { column(for: $0) }
    }

    func key(of column: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: storage[offsets[column]..<offsets[column + 1]])
    }

    @inline(__always)
    func matches(_ column: Int, _ key: UnsafeBufferPointer<UInt8>) -> Bool {
        Self.matches(column, key, storage: storage, offsets: offsets)
    }

    @inline(__always)
    static func matches(
        _ column: Int,
        _ key: UnsafeBufferPointer<UInt8>,
        storage: UnsafeBufferPointer<UInt8>,
        offsets: UnsafeBufferPointer<Int>
    ) -> Bool {
        let start = offsets[column]
        let length = offsets[column + 1] - start
        guard length == key.count else { return false }
        guard length > 0, let keyBase = key.baseAddress, let base = storage.baseAddress else { return true }
        return JSONWord.equal(base + start, keyBase, count: length)
    }

    func column(for key: UnsafeBufferPointer<UInt8>) -> Int? {
        guard !slots.isEmpty else { return nil }
        let hash = Self.hash(key)
        let mask = slots.count - 1
        var position = Int(truncatingIfNeeded: hash) & mask
        while true {
            let slot = slots[position]
            if slot < 0 { return nil }
            let column = Int(slot)
            if hashes[column] == hash, matches(column, key) { return column }
            position = (position + 1) & mask
        }
    }
}

internal struct JSONKeyPredictor {
    private var expected: [Int] = []

    @inline(__always)
    mutating func column(for key: UnsafeBufferPointer<UInt8>, ordinal: Int, in lookup: JSONKeyLookup) -> Int? {
        if ordinal < expected.count {
            let predicted = expected[ordinal]
            if predicted >= 0, lookup.matches(predicted, key) { return predicted }
        }
        let resolved = lookup.column(for: key)
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
