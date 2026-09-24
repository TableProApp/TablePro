import Foundation
import TableProTabularIO

public struct TabularColumnID: Hashable, Comparable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: TabularColumnID, rhs: TabularColumnID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TabularValueStore: Sendable, Equatable {
    public private(set) var bytes: [UInt8] = []
    public private(set) var ends: [Int] = []
    public private(set) var kinds: [TabularCellKind] = []

    public init() {}

    public var count: Int { ends.count }

    public mutating func reserve(values: Int, bytes byteCount: Int) {
        ends.reserveCapacity(values)
        kinds.reserveCapacity(values)
        bytes.reserveCapacity(byteCount)
    }

    public mutating func append(_ value: UnsafeBufferPointer<UInt8>, kind: TabularCellKind) {
        bytes.append(contentsOf: value)
        ends.append(bytes.count)
        kinds.append(kind)
    }

    public mutating func append(_ value: String, kind: TabularCellKind) {
        bytes.append(contentsOf: value.utf8)
        ends.append(bytes.count)
        kinds.append(kind)
    }

    public mutating func appendBuilt(kind: TabularCellKind, _ build: (inout [UInt8]) -> Void) {
        build(&bytes)
        ends.append(bytes.count)
        kinds.append(kind)
    }

    public mutating func append(contentsOf other: TabularValueStore) {
        let offset = bytes.count
        bytes.append(contentsOf: other.bytes)
        ends.append(contentsOf: other.ends.map { $0 + offset })
        kinds.append(contentsOf: other.kinds)
    }

    public func withValue<R>(at slot: Int, _ body: (TabularCellKind, UnsafeBufferPointer<UInt8>) -> R) -> R {
        let start = slot == 0 ? 0 : ends[slot - 1]
        let end = ends[slot]
        return bytes.withUnsafeBufferPointer { buffer in
            body(kinds[slot], UnsafeBufferPointer(rebasing: buffer[start..<end]))
        }
    }

    public func cell(at slot: Int) -> TabularCell {
        withValue(at: slot) { kind, value in
            TabularCell(kind: kind, text: TabularTextCodec.utf8String(value))
        }
    }
}

public enum ColumnBase: Sendable, Equatable {
    case source(Int)
    case constant(TabularCell)
    case dense(TabularValueStore)
}

public struct ColumnPatch: Sendable, Equatable {
    public private(set) var keys: [Int] = []
    public private(set) var values = TabularValueStore()

    public init() {}

    public init(sortedKeys: [Int], values: TabularValueStore) {
        precondition(sortedKeys.count == values.count)
        self.keys = sortedKeys
        self.values = values
    }

    public var isEmpty: Bool { keys.isEmpty }

    public func slot(forKey key: Int) -> Int? {
        var low = 0
        var high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < keys.count && keys[low] == key ? low : nil
    }

    public func merged(over older: ColumnPatch) -> ColumnPatch {
        guard !older.isEmpty else { return self }
        guard !isEmpty else { return older }
        var mergedKeys: [Int] = []
        var mergedValues = TabularValueStore()
        mergedKeys.reserveCapacity(keys.count + older.keys.count)
        var newer = 0
        var old = 0
        while newer < keys.count || old < older.keys.count {
            let takeNewer: Bool
            if newer == keys.count {
                takeNewer = false
            } else if old == older.keys.count {
                takeNewer = true
            } else {
                takeNewer = keys[newer] <= older.keys[old]
            }
            if takeNewer {
                if old < older.keys.count, older.keys[old] == keys[newer] {
                    old += 1
                }
                mergedKeys.append(keys[newer])
                values.withValue(at: newer) { mergedValues.append($1, kind: $0) }
                newer += 1
            } else {
                mergedKeys.append(older.keys[old])
                older.values.withValue(at: old) { mergedValues.append($1, kind: $0) }
                old += 1
            }
        }
        return ColumnPatch(sortedKeys: mergedKeys, values: mergedValues)
    }
}

public struct ColumnValues: Sendable, Equatable {
    public var base: ColumnBase
    public var patch: ColumnPatch
    public var edits: [Int: TabularCell]

    public init(base: ColumnBase, patch: ColumnPatch = ColumnPatch(), edits: [Int: TabularCell] = [:]) {
        self.base = base
        self.patch = patch
        self.edits = edits
    }

    public var sourceColumn: Int? {
        guard case .source(let column) = base else { return nil }
        return column
    }

    public var isPristineSource: Bool {
        sourceColumn != nil && patch.isEmpty && edits.isEmpty
    }

    public func overrides(key: Int) -> Bool {
        edits[key] != nil || patch.slot(forKey: key) != nil
    }
}
