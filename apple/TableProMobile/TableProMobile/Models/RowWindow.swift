import Foundation
import TableProModels

struct RowWindow: Sendable {
    private(set) var rows: [Row]
    private(set) var firstAbsoluteIndex: Int
    private(set) var totalAppended: Int
    private(set) var clears = 0
    let capacity: Int

    // Changes whenever the first rows may have, so a view can tell without reading them.
    struct HeadIdentity: Equatable, Sendable {
        let clears: Int
        let firstAbsoluteIndex: Int
        let count: Int
    }

    init(capacity: Int = 200) {
        self.rows = []
        self.firstAbsoluteIndex = 0
        self.totalAppended = 0
        self.capacity = max(1, capacity)
    }

    mutating func append(_ row: Row) {
        rows.append(row)
        totalAppended += 1
        slideForwardIfOverCapacity()
    }

    mutating func append(contentsOf newRows: [Row]) {
        for row in newRows {
            append(row)
        }
    }

    mutating func shrink(to maxCount: Int) {
        guard maxCount >= 0, rows.count > maxCount else { return }
        let dropCount = rows.count - maxCount
        rows.removeFirst(dropCount)
        firstAbsoluteIndex += dropCount
    }

    mutating func clear() {
        rows = []
        firstAbsoluteIndex = 0
        totalAppended = 0
        clears += 1
    }

    func headIdentity(count: Int) -> HeadIdentity {
        HeadIdentity(clears: clears, firstAbsoluteIndex: firstAbsoluteIndex, count: min(rows.count, count))
    }

    var isEmpty: Bool {
        rows.isEmpty
    }

    var count: Int {
        rows.count
    }

    func row(atAbsolute absoluteIndex: Int) -> Row? {
        let relative = absoluteIndex - firstAbsoluteIndex
        guard rows.indices.contains(relative) else { return nil }
        return rows[relative]
    }

    private mutating func slideForwardIfOverCapacity() {
        guard rows.count > capacity else { return }
        let dropCount = rows.count - capacity
        rows.removeFirst(dropCount)
        firstAbsoluteIndex += dropCount
    }
}
