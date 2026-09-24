import Foundation
import TableProTabularIO

public extension TabularTable {
    func scan(
        columns ids: [TabularColumnID],
        rows logicalRows: Range<Int>,
        _ body: (Int, TabularRowCells) -> Bool
    ) {
        scan(columns: ids, logicalRows: logicalRows.clamped(to: 0..<rowCount), body)
    }

    func scan<Rows: Collection>(
        columns ids: [TabularColumnID],
        logicalRows clamped: Rows,
        _ body: (Int, TabularRowCells) -> Bool
    ) where Rows.Element == Int {
        guard !ids.isEmpty, !clamped.isEmpty else { return }
        let plan = ScanPlan(table: self, ids: ids)
        var buffer = TabularCellBuffer()
        var batch: [Int] = []
        var batchRows: [Int] = []
        batch.reserveCapacity(min(clamped.count, 4_096))
        batchRows.reserveCapacity(min(clamped.count, 4_096))
        var stopped = false

        func flushBatch() {
            guard !batch.isEmpty, !stopped else { return }
            var position = 0
            source.scan(columns: plan.sourceColumns, rows: batch) { key, sourceCells in
                while position < batch.count, batch[position] != key {
                    position += 1
                }
                let logicalRow = position < batchRows.count ? batchRows[position] : 0
                position += 1
                let keepGoing = plan.assemble(key: key, sourceCells: sourceCells, into: &buffer) { cells in
                    body(logicalRow, cells)
                }
                if !keepGoing { stopped = true }
                return keepGoing
            }
            batch.removeAll(keepingCapacity: true)
            batchRows.removeAll(keepingCapacity: true)
        }

        for logicalRow in clamped {
            if stopped { return }
            guard logicalRow >= 0, logicalRow < rowCount else { continue }
            let key = rowOrder.key(at: logicalRow)
            if isSourceKey(key), !plan.sourceColumns.isEmpty {
                batch.append(key)
                batchRows.append(logicalRow)
                if batch.count >= 4_096 { flushBatch() }
                continue
            }
            flushBatch()
            if stopped { return }
            let keepGoing = plan.assemble(key: key, sourceCells: nil, into: &buffer) { cells in
                body(logicalRow, cells)
            }
            if !keepGoing { return }
        }
        flushBatch()
    }

    func textValues(column id: TabularColumnID, rows logicalRows: Range<Int>) -> [String] {
        var result: [String] = []
        result.reserveCapacity(logicalRows.count)
        scan(columns: [id], rows: logicalRows) { _, cells in
            result.append(cells.string(at: 0))
            return true
        }
        return result
    }
}

private struct ScanPlan {
    let table: TabularTable
    let columns: [TabularColumn]
    let sourceColumns: [Int]
    let sourceSlotForOutput: [Int?]

    init(table: TabularTable, ids: [TabularColumnID]) {
        self.table = table
        var resolved: [TabularColumn] = []
        var sourceColumns: [Int] = []
        var slots: [Int?] = []
        for id in ids {
            guard let column = table.column(id) else {
                resolved.append(TabularColumn(id: id, name: "", values: ColumnValues(base: .constant(table.source.absentCell))))
                slots.append(nil)
                continue
            }
            resolved.append(column)
            if let sourceColumn = column.values.sourceColumn {
                slots.append(sourceColumns.count)
                sourceColumns.append(sourceColumn)
            } else {
                slots.append(nil)
            }
        }
        columns = resolved
        self.sourceColumns = sourceColumns
        sourceSlotForOutput = slots
    }

    func assemble(
        key: Int,
        sourceCells: TabularRowCells?,
        into buffer: inout TabularCellBuffer,
        _ body: (TabularRowCells) -> Bool
    ) -> Bool {
        buffer.reset(slots: columns.count, fill: .text)
        for (slot, column) in columns.enumerated() {
            let values = column.values
            if let edited = values.edits[key] {
                buffer.setUTF8(slot, edited.text, kind: edited.kind)
                continue
            }
            if !values.patch.isEmpty, let patchSlot = values.patch.slot(forKey: key) {
                values.patch.values.withValue(at: patchSlot) { kind, bytes in
                    buffer.setCopy(slot, bytes, kind: kind)
                }
                continue
            }
            if let sourceSlot = sourceSlotForOutput[slot] {
                guard let sourceCells else {
                    let absent = table.source.absentCell
                    buffer.setUTF8(slot, absent.text, kind: absent.kind)
                    continue
                }
                buffer.setExternal(slot, sourceCells.bytes[sourceSlot], kind: sourceCells.kinds[sourceSlot])
                continue
            }
            switch values.base {
            case .source:
                let absent = table.source.absentCell
                buffer.setUTF8(slot, absent.text, kind: absent.kind)
            case .constant(let cell):
                buffer.setUTF8(slot, cell.text, kind: cell.kind)
            case .dense(let store):
                guard key < store.count else {
                    let absent = table.source.absentCell
                    buffer.setUTF8(slot, absent.text, kind: absent.kind)
                    continue
                }
                store.withValue(at: key) { kind, bytes in
                    buffer.setCopy(slot, bytes, kind: kind)
                }
            }
        }
        return buffer.withResolved(body)
    }
}
