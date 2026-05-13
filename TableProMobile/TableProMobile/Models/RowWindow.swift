import Foundation
import TableProModels

struct RowWindow: Sendable {
    private(set) var rows: [Row]
    private(set) var firstAbsoluteIndex: Int
    private(set) var totalAppended: Int
    let capacity: Int

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
    }

    var lastAbsoluteIndex: Int {
        firstAbsoluteIndex + rows.count - 1
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
