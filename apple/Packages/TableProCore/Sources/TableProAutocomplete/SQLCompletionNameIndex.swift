import Foundation

// A catalog's table list, folded once per list so a request ranks it without building an item per table.
// Names of printable ASCII rank on their UTF-16 keys, where the provider's string matching reads the same units;
// any other name goes through the provider's own matcher, so the order never depends on which path a name took.
public struct SQLCompletionNameIndex: Sendable {
    let names: [String]
    let isView: [Bool]
    // The folded key of every simple row, back to back; a row's key is `units[starts[row]..<starts[row + 1]]`.
    let units: [UInt16]
    let starts: [Int32]
    let isSimple: [Bool]
    // Simple rows in key order, ties in list order, so a typed prefix is one contiguous range.
    let sortedRows: [Int32]
    let complexRows: [Int32]

    public var count: Int { names.count }

    public init(tables: [(name: String, isView: Bool)]) {
        var names: [String] = []
        var isView: [Bool] = []
        var units: [UInt16] = []
        var starts: [Int32] = [0]
        var isSimple: [Bool] = []
        var complexRows: [Int32] = []
        names.reserveCapacity(tables.count)
        isView.reserveCapacity(tables.count)
        starts.reserveCapacity(tables.count + 1)
        isSimple.reserveCapacity(tables.count)

        for (row, table) in tables.enumerated() {
            names.append(table.name)
            isView.append(table.isView)
            if let key = Self.simpleKey(table.name) {
                units.append(contentsOf: key)
                isSimple.append(true)
            } else {
                isSimple.append(false)
                complexRows.append(Int32(row))
            }
            starts.append(Int32(units.count))
        }

        var sortedRows = (0..<Int32(tables.count)).filter { isSimple[Int($0)] }
        units.withUnsafeBufferPointer { buffer in
            sortedRows.sort { lhs, rhs in
                let order = Self.compare(
                    buffer, Int(starts[Int(lhs)]), Int(starts[Int(lhs) + 1]),
                    buffer, Int(starts[Int(rhs)]), Int(starts[Int(rhs) + 1])
                )
                return order == 0 ? lhs < rhs : order < 0
            }
        }

        self.names = names
        self.isView = isView
        self.units = units
        self.starts = starts
        self.isSimple = isSimple
        self.sortedRows = sortedRows
        self.complexRows = complexRows
    }

    func item(at row: Int) -> SQLCompletionItem {
        SQLCompletionItem.table(names[row], isView: isView[row])
    }

    // The provider's matcher lowercases the label; on printable ASCII that is the same units, one per character.
    static func simpleKey(_ text: String) -> [UInt16]? {
        var key: [UInt16] = []
        key.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            guard byte >= 0x20, byte <= 0x7E else { return nil }
            key.append(UInt16(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte))
        }
        return key
    }

    static func compare(
        _ left: UnsafeBufferPointer<UInt16>, _ leftStart: Int, _ leftEnd: Int,
        _ right: UnsafeBufferPointer<UInt16>, _ rightStart: Int, _ rightEnd: Int
    ) -> Int {
        var leftIndex = leftStart
        var rightIndex = rightStart
        while leftIndex < leftEnd, rightIndex < rightEnd {
            let lhs = left[leftIndex]
            let rhs = right[rightIndex]
            if lhs != rhs { return lhs < rhs ? -1 : 1 }
            leftIndex += 1
            rightIndex += 1
        }
        let leftLength = leftEnd - leftStart
        let rightLength = rightEnd - rightStart
        return leftLength == rightLength ? 0 : (leftLength < rightLength ? -1 : 1)
    }

    // The `sortedRows` slice whose keys start with `prefix`.
    func prefixRange(_ prefix: [UInt16]) -> Range<Int> {
        units.withUnsafeBufferPointer { keys in
            prefix.withUnsafeBufferPointer { typed in
                // Below the range a key orders before the prefix; in it, its first units equal the prefix.
                func ordersBelow(_ row: Int32, inclusive: Bool) -> Bool {
                    let start = Int(starts[Int(row)])
                    let end = min(Int(starts[Int(row) + 1]), start + typed.count)
                    let order = Self.compare(keys, start, end, typed, 0, typed.count)
                    return inclusive ? order <= 0 : order < 0
                }
                let lower = partition { !ordersBelow($0, inclusive: false) }
                let upper = partition { !ordersBelow($0, inclusive: true) }
                return lower..<max(lower, upper)
            }
        }
    }

    private func partition(_ isAtOrAbove: (Int32) -> Bool) -> Int {
        var low = 0
        var high = sortedRows.count
        while low < high {
            let middle = (low + high) / 2
            if isAtOrAbove(sortedRows[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
