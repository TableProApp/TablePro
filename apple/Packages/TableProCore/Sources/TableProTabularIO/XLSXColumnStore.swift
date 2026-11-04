import Foundation

struct XLSXColumnStore: Sendable {
    private let isDense: Bool
    private let firstRow: Int
    private let rowOrigin: Int
    private let rows: XLSXChunkedArray<UInt32>
    let kinds: XLSXChunkedArray<UInt8>
    let payloads: XLSXChunkedArray<UInt64>

    static let empty = XLSXColumnStore(
        isDense: true,
        firstRow: 0,
        rowOrigin: 0,
        rows: XLSXChunkedArray(),
        kinds: XLSXChunkedArray(),
        payloads: XLSXChunkedArray()
    )

    init(
        isDense: Bool,
        firstRow: Int,
        rowOrigin: Int,
        rows: XLSXChunkedArray<UInt32>,
        kinds: XLSXChunkedArray<UInt8>,
        payloads: XLSXChunkedArray<UInt64>
    ) {
        self.isDense = isDense
        self.firstRow = firstRow
        self.rowOrigin = rowOrigin
        self.rows = rows
        self.kinds = kinds
        self.payloads = payloads
    }

    func slot(forRow row: Int, hint: inout Int) -> Int? {
        guard isDense else { return sparseSlot(forRow: row, hint: &hint) }
        let slot = row - firstRow
        guard slot >= 0, slot < kinds.count, kinds[slot] != XLSXStoredCell.empty else { return nil }
        return slot
    }

    private func sparseSlot(forRow row: Int, hint: inout Int) -> Int? {
        let target = UInt32(clamping: row + rowOrigin)
        let next = hint + 1
        let slot: Int
        if next >= 0, next < rows.count, rows[next] == target {
            slot = next
        } else {
            slot = rows.lowerBound(of: target)
            guard slot < rows.count, rows[slot] == target else { return nil }
        }
        hint = slot
        return kinds[slot] == XLSXStoredCell.empty ? nil : slot
    }

    func forEachOccupiedRow(_ body: (Int) -> Void) {
        for slot in 0..<kinds.count where kinds[slot] != XLSXStoredCell.empty {
            body(isDense ? firstRow + slot : Int(rows[slot]) - rowOrigin)
        }
    }
}

struct XLSXColumnBuilder {
    // Gap filling never passes this many slots per stored cell, so a few cells far apart cannot make a column dense.
    private static let largestDenseSpread = 65

    private var firstRow = 0
    private var lastRow = -1
    private var storedCount = 0
    private var isDense = true
    private var isSorted = true
    private var rows = XLSXChunkedArray<UInt32>()
    private var kinds = XLSXChunkedArray<UInt8>()
    private var payloads = XLSXChunkedArray<UInt64>()

    var isEmpty: Bool { kinds.isEmpty }

    var lastRowIndex: Int { lastRow }

    mutating func append(row: Int, kind: UInt8, payload: UInt64) {
        guard !kinds.isEmpty else {
            firstRow = row
            lastRow = row
            kinds.append(kind)
            payloads.append(payload)
            storedCount = 1
            return
        }
        if row == lastRow, isSorted {
            kinds[kinds.count - 1] = kind
            payloads[payloads.count - 1] = payload
            return
        }
        if row < lastRow {
            appendOutOfOrder(row: row, kind: kind, payload: payload)
            return
        }
        let gap = row - lastRow - 1
        if isDense, gap > 0 {
            let spread = kinds.count + gap < Self.largestDenseSpread * (storedCount + 1)
            if gap <= max(64, kinds.count / 8), spread {
                kinds.append(XLSXStoredCell.empty, times: gap)
                payloads.append(0, times: gap)
            } else {
                makeSparse()
            }
        }
        if !isDense { rows.append(UInt32(row)) }
        kinds.append(kind)
        payloads.append(payload)
        storedCount += 1
        lastRow = row
    }

    mutating func clear(where isHidden: (Int) -> Bool) {
        normalize()
        for slot in 0..<kinds.count where kinds[slot] != XLSXStoredCell.empty && isHidden(row(at: slot)) {
            kinds[slot] = XLSXStoredCell.empty
        }
    }

    mutating func occupiedRows() -> ClosedRange<Int>? {
        normalize()
        guard let first = kinds.firstIndex(where: { $0 != XLSXStoredCell.empty }),
              let last = kinds.lastIndex(where: { $0 != XLSXStoredCell.empty }) else { return nil }
        return row(at: first)...row(at: last)
    }

    mutating func makeStore(rowOrigin: Int) -> XLSXColumnStore {
        normalize()
        return XLSXColumnStore(
            isDense: isDense,
            firstRow: firstRow - rowOrigin,
            rowOrigin: rowOrigin,
            rows: rows,
            kinds: kinds,
            payloads: payloads
        )
    }

    private func row(at slot: Int) -> Int {
        isDense ? firstRow + slot : Int(rows[slot])
    }

    private mutating func appendOutOfOrder(row: Int, kind: UInt8, payload: UInt64) {
        if isDense { makeSparse() }
        rows.append(UInt32(row))
        kinds.append(kind)
        payloads.append(payload)
        storedCount += 1
        isSorted = false
    }

    private mutating func makeSparse() {
        let start = firstRow
        rows = XLSXChunkedArray((0..<kinds.count).lazy.map { UInt32(start + $0) })
        isDense = false
    }

    private mutating func normalize() {
        guard !isSorted else { return }
        let order = (0..<rows.count).sorted { lhs, rhs in
            rows[lhs] != rows[rhs] ? rows[lhs] < rows[rhs] : lhs < rhs
        }
        var sortedRows: [UInt32] = []
        var sortedKinds: [UInt8] = []
        var sortedPayloads: [UInt64] = []
        sortedRows.reserveCapacity(order.count)
        sortedKinds.reserveCapacity(order.count)
        sortedPayloads.reserveCapacity(order.count)
        for index in order {
            if let last = sortedRows.last, last == rows[index] {
                sortedKinds[sortedKinds.count - 1] = kinds[index]
                sortedPayloads[sortedPayloads.count - 1] = payloads[index]
                continue
            }
            sortedRows.append(rows[index])
            sortedKinds.append(kinds[index])
            sortedPayloads.append(payloads[index])
        }
        rows = XLSXChunkedArray(sortedRows)
        kinds = XLSXChunkedArray(sortedKinds)
        payloads = XLSXChunkedArray(sortedPayloads)
        lastRow = Int(sortedRows.last ?? 0)
        isSorted = true
    }
}
