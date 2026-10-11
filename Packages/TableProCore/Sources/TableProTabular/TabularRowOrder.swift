import Foundation

public enum TabularRowOrder: Sendable, Equatable {
    case range(Range<Int>)
    case explicit([Int])

    public var count: Int {
        switch self {
        case .range(let range): return range.count
        case .explicit(let keys): return keys.count
        }
    }

    public func key(at logicalRow: Int) -> Int {
        switch self {
        case .range(let range): return range.lowerBound + logicalRow
        case .explicit(let keys): return keys[logicalRow]
        }
    }

    public var keys: [Int] {
        switch self {
        case .range(let range): return Array(range)
        case .explicit(let keys): return keys
        }
    }

    public func keys(in logicalRows: Range<Int>) -> [Int] {
        switch self {
        case .range(let range):
            return Array((range.lowerBound + logicalRows.lowerBound)..<(range.lowerBound + logicalRows.upperBound))
        case .explicit(let keys):
            return Array(keys[logicalRows])
        }
    }

    public func logicalRow(ofKey key: Int) -> Int? {
        switch self {
        case .range(let range):
            return range.contains(key) ? key - range.lowerBound : nil
        case .explicit(let keys):
            return keys.firstIndex(of: key)
        }
    }

    public func inserting(_ newKeys: [Int], at logicalRow: Int) -> TabularRowOrder {
        var all = keys
        all.insert(contentsOf: newKeys, at: min(max(0, logicalRow), all.count))
        return .explicit(all)
    }

    public func removing(logicalRows: IndexSet) -> TabularRowOrder {
        guard !logicalRows.isEmpty else { return self }
        var kept: [Int] = []
        kept.reserveCapacity(max(0, count - logicalRows.count))
        for logicalRow in 0..<count where !logicalRows.contains(logicalRow) {
            kept.append(key(at: logicalRow))
        }
        return .explicit(kept)
    }

    public func removing(keys removed: Set<Int>) -> TabularRowOrder {
        guard !removed.isEmpty else { return self }
        return .explicit(keys.filter { !removed.contains($0) })
    }
}
