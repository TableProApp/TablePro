import Foundation
import TableProMemcachedCore
import TableProPluginKit

/// Turns grid edits into console commands: `set` for a new row or a new value or flags, `touch` for a TTL alone,
/// `delete` for a removed row. The key names the item, so it is never rewritten in place.
struct MemcachedStatementGenerator {
    let columns: [String]
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }

    func generateRowWrites(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []
        for change in changes {
            let statement: String?
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                statement = try insertStatement(for: change, row: insertedRowData[change.rowIndex])
            case .update:
                statement = try updateStatement(for: change)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                statement = MemcachedStatements.delete(key: try originalKey(of: change))
            }
            if let statement { writes.append(PluginRowWrite(statement: statement, rowIndices: [change.rowIndex])) }
        }
        return writes
    }

    private func insertStatement(for change: PluginRowChange, row: [PluginCellValue]?) throws -> String {
        var cells: [MemcachedColumn: PluginCellValue] = [:]
        if let row {
            for column in MemcachedColumn.allCases {
                if let index = columns.firstIndex(of: column.rawValue), index < row.count { cells[column] = row[index] }
            }
        } else {
            for cell in change.cellChanges {
                if let column = MemcachedColumn(rawValue: cell.columnName) { cells[column] = cell.newValue }
            }
        }
        guard let key = cells[.key]?.asText, !key.isEmpty else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(localized: "A new key needs a name."))
        }
        try validate(key: key, rowIndex: change.rowIndex)
        return setStatement(
            key: key,
            flags: try number(cells[.flags], of: .flags, rowIndex: change.rowIndex) ?? 0,
            ttl: try number(cells[.ttl], of: .ttl, rowIndex: change.rowIndex),
            value: cells[.value] ?? .null
        )
    }

    private func updateStatement(for change: PluginRowChange) throws -> String? {
        guard !change.cellChanges.isEmpty else { return nil }
        let key = try originalKey(of: change)
        var edited: [MemcachedColumn: PluginCellValue] = [:]
        for cell in change.cellChanges {
            guard let column = MemcachedColumn(rawValue: cell.columnName) else { continue }
            guard column != .key else {
                throw PluginRowWriteRefusal(
                    rowIndex: change.rowIndex,
                    reason: String(localized: "A key cannot be renamed. Add a row with the new key instead.")
                )
            }
            edited[column] = cell.newValue
        }
        let ttl = try number(edited[.ttl] ?? original(.ttl, of: change), of: .ttl, rowIndex: change.rowIndex)
        guard edited[.value] != nil || edited[.flags] != nil else {
            return edited[.ttl] == nil ? nil : MemcachedStatements.touch(key: key, exptime: exptime(forTTL: ttl))
        }
        return setStatement(
            key: key,
            flags: try number(edited[.flags] ?? original(.flags, of: change), of: .flags, rowIndex: change.rowIndex) ?? 0,
            ttl: ttl,
            value: edited[.value] ?? original(.value, of: change) ?? .null
        )
    }

    private func setStatement(key: String, flags: Int64, ttl: Int64?, value: PluginCellValue) -> String {
        let flags = UInt32(flags)
        if case .bytes(let data) = value {
            return MemcachedStatements.set(key: key, flags: flags, exptime: exptime(forTTL: ttl), bytes: data)
        }
        return MemcachedStatements.set(key: key, flags: flags, exptime: exptime(forTTL: ttl), value: value.asText ?? "")
    }

    private func exptime(forTTL ttl: Int64?) -> Int64 {
        MemcachedStatements.exptime(forTTL: ttl, now: now())
    }

    private func number(_ cell: PluginCellValue?, of column: MemcachedColumn, rowIndex: Int) throws -> Int64? {
        guard let text = cell?.asText?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let limit: ClosedRange<Int64> = column == .flags ? 0 ... Int64(UInt32.max) : Int64.min ... Int64.max
        guard let value = Int64(text), limit.contains(value) else {
            throw PluginRowWriteRefusal(
                rowIndex: rowIndex,
                reason: String(format: String(localized: "%@ must be a whole number."), column.rawValue)
            )
        }
        return value
    }

    private func validate(key: String, rowIndex: Int) throws {
        guard MemcachedCommandParser.isValidKey(Array(key.utf8)) else {
            throw PluginRowWriteRefusal(
                rowIndex: rowIndex,
                reason: String(localized: "A key is 1 to 250 bytes with no spaces or control characters.")
            )
        }
    }

    private func originalKey(of change: PluginRowChange) throws -> String {
        guard let key = original(.key, of: change)?.asText, MemcachedCommandParser.isValidKey(Array(key.utf8)) else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "This row's key cannot be addressed from the grid.")
            )
        }
        return key
    }

    private func original(_ column: MemcachedColumn, of change: PluginRowChange) -> PluginCellValue? {
        guard let index = columns.firstIndex(of: column.rawValue),
              let row = change.originalRow, index < row.count else { return nil }
        return row[index]
    }
}
