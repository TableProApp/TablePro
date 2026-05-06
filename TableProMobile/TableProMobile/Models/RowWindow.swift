//
//  RowWindow.swift
//  TableProMobile
//

import Foundation
import TableProModels

public struct RowWindow: Sendable {
    public private(set) var rows: [Row]
    public private(set) var firstAbsoluteIndex: Int
    public private(set) var totalAppended: Int
    public let capacity: Int

    public init(capacity: Int = 200) {
        self.rows = []
        self.firstAbsoluteIndex = 0
        self.totalAppended = 0
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ row: Row) {
        rows.append(row)
        totalAppended += 1
        slideForwardIfOverCapacity()
    }

    public mutating func append(contentsOf newRows: [Row]) {
        for row in newRows {
            append(row)
        }
    }

    public mutating func shrink(to maxCount: Int) {
        guard maxCount >= 0, rows.count > maxCount else { return }
        let dropCount = rows.count - maxCount
        rows.removeFirst(dropCount)
        firstAbsoluteIndex += dropCount
    }

    public mutating func clear() {
        rows = []
        firstAbsoluteIndex = 0
        totalAppended = 0
    }

    public var lastAbsoluteIndex: Int {
        firstAbsoluteIndex + rows.count - 1
    }

    public var isEmpty: Bool {
        rows.isEmpty
    }

    public var count: Int {
        rows.count
    }

    public func row(atAbsolute absoluteIndex: Int) -> Row? {
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
