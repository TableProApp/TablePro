//
//  EtcdStatementGenerator.swift
//  EtcdDriverPlugin
//

import Foundation
import TableProEtcdCore
import TableProPluginKit

struct EtcdStatementGenerator {
    let prefix: String
    let columns: [String]

    var keyColumnIndex: Int? { columns.firstIndex(of: "Key") }
    private var valueColumnIndex: Int? { columns.firstIndex(of: "Value") }
    private var leaseColumnIndex: Int? { columns.firstIndex(of: "Lease") }
    private var modRevisionColumnIndex: Int? { columns.firstIndex(of: "ModRevision") }

    // etcd stores no NULL, so a NULL written to Value means an empty value, and to Lease, no lease.
    private static let writableColumns: Set<String> = ["Key", "Value", "Lease"]

    // A change carrying a value these commands cannot express is refused whole: writing the rest of it
    // would let the save succeed and clear the value it left out.
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
                commands = [EtcdCommandText.command("del", arguments: [key])]
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

        var key: Data?
        var value: Data?
        var leaseId: String?

        if let values = insertedRowData[change.rowIndex] {
            if let ki = keyColumnIndex, ki < values.count { key = values[ki].etcdBytes }
            if let vi = valueColumnIndex, vi < values.count { value = values[vi].etcdBytes }
            if let li = leaseColumnIndex, li < values.count { leaseId = values[li].asText }
        } else {
            for cellChange in change.cellChanges {
                switch cellChange.columnName {
                case "Key": key = cellChange.newValue.etcdBytes
                case "Value": value = cellChange.newValue.etcdBytes
                case "Lease": leaseId = cellChange.newValue.asText
                default: break
                }
            }
        }

        guard let k = key, !k.isEmpty else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(localized: "A new key needs a name."))
        }

        // A key typed without a leading slash lands under the table's prefix.
        let fullKey = !prefix.isEmpty && k.first != UInt8(ascii: "/") ? Data(prefix.utf8) + k : k
        return [Self.writeCommand("create", arguments: [fullKey, value ?? Data()], lease: leaseId)]
    }

    private func updateCommands(for change: PluginRowChange) throws -> [String] {
        guard !change.cellChanges.isEmpty else { return [] }
        guard let originalKey = extractKey(from: change) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.unaddressableKeyReason)
        }
        if let column = serverOwnedColumn(in: change) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.serverOwnedReason(column))
        }

        let keyChange = change.cellChanges.first { $0.columnName == "Key" }
        let valueChange = change.cellChanges.first { $0.columnName == "Value" }
        let leaseChange = change.cellChanges.first { $0.columnName == "Lease" }

        let newKey = keyChange.map { $0.newValue.etcdBytes ?? Data() } ?? originalKey
        guard !newKey.isEmpty else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(localized: "A key needs a name."))
        }

        let shouldDeleteOriginalKey = newKey != originalKey
        let editedLease = leaseChange.map { $0.newValue.asText ?? "" }
        let lease = editedLease ?? originalCell(at: leaseColumnIndex, of: change)?.asText

        let newValue = valueChange.map { $0.newValue.etcdBytes ?? Data() } ?? originalValue(of: change)
        if shouldDeleteOriginalKey {
            // One transaction: a put and a del sent apart replace a key already at the new name
            // and leave both keys behind when the del fails.
            let revision = originalCell(at: modRevisionColumnIndex, of: change)?.asText.flatMap { Int64($0) }
            return [Self.writeCommand(
                "mv",
                arguments: [originalKey, newKey, newValue],
                lease: lease,
                flags: revision.map { ["--mod-rev=\($0)"] } ?? []
            )]
        }
        guard valueChange != nil || editedLease != nil else { return [] }
        return [Self.writeCommand("put", arguments: [newKey, newValue], lease: lease)]
    }

    private static func writeCommand(_ name: String, arguments: [Data], lease: String?, flags: [String] = []) -> String {
        guard let lease, !lease.isEmpty, lease != "0" else {
            return EtcdCommandText.command(name, arguments: arguments, flags: flags)
        }
        return EtcdCommandText.command(
            name, arguments: arguments, flags: flags + ["--lease=" + EtcdCommandText.quoted(lease)]
        )
    }

    // A new row's NULL in a server-owned column leaves the value to etcd, so only a value set in one counts.
    private func serverOwnedColumn(in change: PluginRowChange) -> String? {
        change.cellChanges
            .first { cell in
                !Self.writableColumns.contains(cell.columnName) && (change.type == .update || !cell.newValue.isNull)
            }?
            .columnName
    }

    // MARK: - Refusals

    private static var unaddressableKeyReason: String {
        String(localized: "This row has no key, so it cannot be addressed from the grid.")
    }

    private static func serverOwnedReason(_ column: String) -> String {
        String(format: String(localized: "'%@' is set by etcd and cannot be edited."), column)
    }

    // MARK: - Helpers

    private func extractKey(from change: PluginRowChange) -> Data? {
        originalCell(at: keyColumnIndex, of: change)?.etcdBytes
    }

    private func originalValue(of change: PluginRowChange) -> Data {
        originalCell(at: valueColumnIndex, of: change)?.etcdBytes ?? Data()
    }

    private func originalCell(at columnIndex: Int?, of change: PluginRowChange) -> PluginCellValue? {
        guard let columnIndex,
              let originalRow = change.originalRow,
              columnIndex < originalRow.count else { return nil }
        return originalRow[columnIndex]
    }
}

struct EtcdGuardedWriteRefusal: Error, PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }
}
