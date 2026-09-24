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
}

struct XLSXColumnBuilder {
    private var firstRow = 0
    private var lastRow = -1
    private var isDense = true
    private var isSorted = true
    private var rows = XLSXChunkedArray<UInt32>()
    private var kinds = XLSXChunkedArray<UInt8>()
    private var payloads = XLSXChunkedArray<UInt64>()

    var isEmpty: Bool { kinds.isEmpty }

    mutating func append(row: Int, kind: UInt8, payload: UInt64) {
        guard !kinds.isEmpty else {
            firstRow = row
            lastRow = row
            kinds.append(kind)
            payloads.append(payload)
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
            if gap <= max(64, kinds.count / 8) {
                kinds.append(XLSXStoredCell.empty, times: gap)
                payloads.append(0, times: gap)
            } else {
                makeSparse()
            }
        }
        if !isDense { rows.append(UInt32(row)) }
        kinds.append(kind)
        payloads.append(payload)
        lastRow = row
    }

    mutating func clear(rows range: ClosedRange<Int>, keeping kept: Int?) {
        normalize()
        for slot in slots(in: range) {
            if let kept, row(at: slot) == kept { continue }
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

    private func slots(in range: ClosedRange<Int>) -> Range<Int> {
        guard !kinds.isEmpty else { return 0..<0 }
        if isDense {
            let lower = max(0, range.lowerBound - firstRow)
            let upper = min(kinds.count, range.upperBound - firstRow + 1)
            return lower < upper ? lower..<upper : 0..<0
        }
        let lower = rows.lowerBound(of: UInt32(clamping: range.lowerBound))
        let upper = rows.lowerBound(of: UInt32(clamping: range.upperBound + 1))
        return lower..<upper
    }

    private mutating func appendOutOfOrder(row: Int, kind: UInt8, payload: UInt64) {
        if isDense { makeSparse() }
        rows.append(UInt32(row))
        kinds.append(kind)
        payloads.append(payload)
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
