import CryptoKit
import Foundation
import TableProMemcachedCore
import TableProPluginKit

/// When a key the grid showed expires, as the server put it. `expiresAt` nil means it never does.
struct MemcachedKnownExpiry: Sendable {
    let expiresAt: Int64?
}

// The unique `gets` returned for a key, with a digest of the Flags and Value the grid showed. A later read, from
// another tab, holds a newer unique, which must not let this row's older Value or Flags be written back.
struct MemcachedLoadedItem: Sendable {
    private let casUnique: UInt64
    private let digest: Data

    init(unique: UInt64, flags: PluginCellValue, value: PluginCellValue) {
        casUnique = unique
        digest = Self.digest(flags: flags, value: value)
    }

    func unique(ifShowing flags: PluginCellValue?, _ value: PluginCellValue?) -> UInt64? {
        guard let flags, let value, Self.digest(flags: flags, value: value) == digest else { return nil }
        return casUnique
    }

    private static func digest(flags: PluginCellValue, value: PluginCellValue) -> Data {
        var hash = SHA256()
        for cell in [flags, value] {
            let tagged: (tag: UInt8, bytes: Data)
            switch cell {
            case .null: tagged = (0, Data())
            case .text(let text): tagged = (1, Data(text.utf8))
            case .bytes(let data): tagged = (2, data)
            }
            hash.update(data: [tagged.tag])
            withUnsafeBytes(of: UInt64(tagged.bytes.count).littleEndian) { hash.update(bufferPointer: $0) }
            hash.update(data: tagged.bytes)
        }
        return Data(hash.finalize())
    }
}

// Grid edits as console commands: `set` for a new row or one that writes both Value and Flags, `cas` for one that keeps
// the loaded Value or Flags, `touch` for a TTL alone, `delete` for a removed row. The key is never rewritten in place.
struct MemcachedStatementGenerator {
    let columns: [String]
    /// The server's clock, so an absolute expiry is compared with the time the server keeps.
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    var knownExpiry: (String) -> MemcachedKnownExpiry? = { _ in nil }
    var loadedItem: (String) -> MemcachedLoadedItem? = { _ in nil }

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
        guard MemcachedCommandParser.isValidKey(Array(key.utf8)) else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "A key is 1 to 250 bytes with no spaces or control characters.")
            )
        }
        let ttl = try number(cells[.ttl], of: .ttl, rowIndex: change.rowIndex)
        return setStatement(
            key: key,
            flags: try number(cells[.flags], of: .flags, rowIndex: change.rowIndex) ?? 0,
            exptime: try exptime(forTTL: ttl, rowIndex: change.rowIndex),
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
        guard let write = MemcachedItemEdit.write(
            editsValue: edited[.value] != nil, editsFlags: edited[.flags] != nil, editsTTL: edited[.ttl] != nil,
            unique: loadedItem(key)?.unique(ifShowing: original(.flags, of: change), original(.value, of: change))
        ) else { return nil }
        switch write {
        case .touch:
            let seconds = try number(edited[.ttl], of: .ttl, rowIndex: change.rowIndex)
            return MemcachedStatements.touch(key: key, exptime: try exptime(forTTL: seconds, rowIndex: change.rowIndex))
        case .needsRefresh:
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "Refresh before changing this item, so the save can check that it has not changed since it was loaded.")
            )
        case .set, .compareAndSwap:
            break
        }
        let exptime: Int64
        if let ttl = edited[.ttl] {
            exptime = try self.exptime(forTTL: try number(ttl, of: .ttl, rowIndex: change.rowIndex), rowIndex: change.rowIndex)
        } else {
            exptime = try currentExptime(of: key, change: change)
        }
        let flags = try number(edited[.flags] ?? original(.flags, of: change), of: .flags, rowIndex: change.rowIndex) ?? 0
        let value = edited[.value] ?? original(.value, of: change) ?? .null
        guard case .compareAndSwap(let unique) = write else {
            return setStatement(key: key, flags: flags, exptime: exptime, value: value)
        }
        return casStatement(key: key, flags: flags, exptime: exptime, unique: unique, value: value)
    }

    // A `set` or `cas` replaces the expiry too, so one that leaves TTL alone sends the time the item already ends at,
    // rather than the TTL the grid read, which has been counting down since.
    private func currentExptime(of key: String, change: PluginRowChange) throws -> Int64 {
        guard let known = knownExpiry(key) else {
            return try exptime(forTTL: try number(original(.ttl, of: change), of: .ttl, rowIndex: change.rowIndex), rowIndex: change.rowIndex)
        }
        guard let expiresAt = known.expiresAt else { return 0 }
        guard expiresAt > now() else {
            throw PluginRowWriteRefusal(
                rowIndex: change.rowIndex,
                reason: String(localized: "This item expired while the grid was open. Refresh to see whether it still exists.")
            )
        }
        return expiresAt
    }

    private func setStatement(key: String, flags: Int64, exptime: Int64, value: PluginCellValue) -> String {
        let flags = UInt32(flags)
        if case .bytes(let data) = value {
            return MemcachedStatements.set(key: key, flags: flags, exptime: exptime, bytes: data)
        }
        return MemcachedStatements.set(key: key, flags: flags, exptime: exptime, value: value.asText ?? "")
    }

    private func casStatement(key: String, flags: Int64, exptime: Int64, unique: UInt64, value: PluginCellValue) -> String {
        let flags = UInt32(flags)
        if case .bytes(let data) = value {
            return MemcachedStatements.cas(key: key, flags: flags, exptime: exptime, unique: unique, bytes: data)
        }
        return MemcachedStatements.cas(key: key, flags: flags, exptime: exptime, unique: unique, value: value.asText ?? "")
    }

    private func exptime(forTTL ttl: Int64?, rowIndex: Int) throws -> Int64 {
        guard let exptime = MemcachedStatements.exptime(forTTL: ttl, now: now()) else {
            throw PluginRowWriteRefusal(rowIndex: rowIndex, reason: String(localized: "This TTL is too large for Memcached."))
        }
        return exptime
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
