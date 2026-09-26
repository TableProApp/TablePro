//
//  EtcdStatementGenerator.swift
//  EtcdDriverPlugin
//
//  Generates etcdctl commands from tracked cell changes.
//

import Foundation
import TableProPluginKit

struct EtcdStatementGenerator {
    let prefix: String
    let columns: [String]

    var keyColumnIndex: Int? { columns.firstIndex(of: "Key") }
    private var valueColumnIndex: Int? { columns.firstIndex(of: "Value") }
    private var leaseColumnIndex: Int? { columns.firstIndex(of: "Lease") }

    /// The columns a `put` can set. The rest, the version and the two revisions, are etcd's own.
    /// etcd stores no NULL, so a NULL written to Value means an empty value, and to Lease, no lease.
    private static let writableColumns: Set<String> = ["Key", "Value", "Lease"]

    /// The commands that write the grid's changes, each naming the change it writes. A change
    /// carrying a value these commands cannot express is refused whole, because writing the rest
    /// of it would let the save succeed and clear the value it left out.
    func generateRowWrites(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []

        for change in changes {
            let commands: [String]
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                commands = try insertCommands(for: change, insertedRowData: insertedRowData)
            case .update:
                commands = try updateCommands(for: change)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                guard let key = extractKey(from: change) else {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.unaddressableKeyReason)
                }
                commands = ["del \(escapeArgument(key))"]
            }
            writes += commands.map { PluginRowWrite(statement: $0, rowIndices: [change.rowIndex]) }
        }

        return writes
    }

    private func insertCommands(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> [String] {
        if let column = serverOwnedColumn(in: change) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.serverOwnedReason(column))
        }

        var key: String?
        var value: String?
        var leaseId: String?

        if let values = insertedRowData[change.rowIndex] {
            if let ki = keyColumnIndex, ki < values.count { key = values[ki].asText }
            if let vi = valueColumnIndex, vi < values.count { value = values[vi].asText }
            if let li = leaseColumnIndex, li < values.count { leaseId = values[li].asText }
        } else {
            for cellChange in change.cellChanges {
                switch cellChange.columnName {
                case "Key": key = cellChange.newValue.asText
                case "Value": value = cellChange.newValue.asText
                case "Lease": leaseId = cellChange.newValue.asText
                default: break
                }
            }
        }

        guard let k = key, !k.isEmpty else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(localized: "A new key needs a name."))
        }

        // Prepend the current browse prefix if the key doesn't already include it
        let fullKey: String
        if !prefix.isEmpty && !k.hasPrefix("/") {
            fullKey = prefix + k
        } else {
            fullKey = k
        }
        let v = value ?? ""
        var cmd = "put \(escapeArgument(fullKey)) \(escapeArgument(v))"
        if let lease = leaseId, !lease.isEmpty, lease != "0" {
            cmd += " --lease=\(lease)"
        }

        return [cmd]
    }

    private func updateCommands(for change: PluginRowChange) throws -> [String] {
        guard !change.cellChanges.isEmpty else { return [] }
        guard let originalKey = extractKey(from: change) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.unaddressableKeyReason)
        }
        if let column = serverOwnedColumn(in: change) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.serverOwnedReason(column))
        }

        var commands: [String] = []

        let keyChange = change.cellChanges.first { $0.columnName == "Key" }
        let valueChange = change.cellChanges.first { $0.columnName == "Value" }
        let leaseChange = change.cellChanges.first { $0.columnName == "Lease" }

        let newKey = keyChange.map { $0.newValue.asText ?? "" } ?? originalKey
        guard !newKey.isEmpty else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(localized: "A key needs a name."))
        }

        let shouldDeleteOriginalKey = newKey != originalKey
        let lease = leaseChange.map { $0.newValue.asText ?? "" }

        if valueChange != nil || newKey != originalKey {
            let newValue = valueChange.map { $0.newValue.asText ?? "" } ?? extractOriginalValue(from: change) ?? ""
            var cmd = "put \(escapeArgument(newKey)) \(escapeArgument(newValue))"
            if let lease, !lease.isEmpty, lease != "0" {
                cmd += " --lease=\(lease)"
            }
            commands.append(cmd)
            if shouldDeleteOriginalKey {
                commands.append("del \(escapeArgument(originalKey))")
            }
        } else if let lease {
            let currentValue = extractOriginalValue(from: change) ?? ""
            var cmd = "put \(escapeArgument(newKey)) \(escapeArgument(currentValue))"
            if !lease.isEmpty && lease != "0" {
                cmd += " --lease=\(lease)"
            }
            commands.append(cmd)
        }

        return commands
    }

    /// An edit to a column no `put` can set, which the save would otherwise drop. A new row's NULL
    /// there leaves the value to etcd, so only a value set in one counts.
    private func serverOwnedColumn(in change: PluginRowChange) -> String? {
        change.cellChanges
            .first { cell in
                !Self.writableColumns.contains(cell.columnName) && (change.type == .update || !cell.newValue.isNull)
            }?
            .columnName
    }

    // MARK: - Refusals

    private static var unaddressableKeyReason: String {
        String(localized: "This key's name is not text, so it cannot be addressed from the grid.")
    }

    private static func serverOwnedReason(_ column: String) -> String {
        String(format: String(localized: "'%@' is set by etcd and cannot be edited."), column)
    }

    // MARK: - Helpers

    private func extractKey(from change: PluginRowChange) -> String? {
        guard let keyIndex = keyColumnIndex,
              let originalRow = change.originalRow,
              keyIndex < originalRow.count else { return nil }
        return originalRow[keyIndex].asText
    }

    private func extractOriginalValue(from change: PluginRowChange) -> String? {
        guard let valueIndex = valueColumnIndex,
              let originalRow = change.originalRow,
              valueIndex < originalRow.count else { return nil }
        return originalRow[valueIndex].asText
    }

    private func escapeArgument(_ value: String) -> String {
        let needsQuoting = value.isEmpty || value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
        if needsQuoting {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escaped)\""
        }
        return value
    }
}
