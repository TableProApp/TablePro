//
//  MongoDBStatementGenerator.swift
//  MongoDBDriverPlugin
//
//  Generates MongoDB shell commands (insertOne, updateOne, deleteOne, deleteMany) from tracked changes.
//  Plugin-local version using PluginRowChange instead of Core types.
//

import Foundation
import os
import TableProNumberFormatting
import TableProPluginKit

struct MongoDBStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoDBStatementGenerator")

    let collectionName: String
    let columns: [String]
    var columnKinds: [String: BsonValueKind] = [:]
    /// Kinds the collection's validator declares. The server rejects any other type for these
    /// fields, so they outrank what the sampled documents happen to hold.
    var declaredKinds: [String: BsonValueKind] = [:]
    /// The kind every sampled `_id` shares, or nil when they differ. An `_id` filter has to carry the
    /// row's own type, and a majority kind would quote an ObjectId in a mostly-string collection and
    /// match nothing.
    var identityKind: BsonValueKind?

    /// The subtype of each binary value the grid shows, so bytes written back keep the subtype they
    /// were read with.
    var binarySubtypes: MongoDBBinarySubtypes = .empty
    /// Fields the validator declares as binary. New bytes with no earlier value there are generic
    /// binary, subtype 0, which is also what the column's `BLOB` type name says.
    var declaredBinaryFields: Set<String> = []
    /// Asked only for a row that needs `$setField`, since reading the version can wait on the
    /// connection.
    var capabilities: () -> MongoDBCapabilities = { .unknown }

    private static let defaultMarker = "__DEFAULT__"

    private var collectionAccessor: String {
        MongoCollectionAccessor.expression(for: collectionName)
    }

    /// Index of "_id" field in the columns array (used as primary key equivalent)
    var idColumnIndex: Int? {
        columns.firstIndex(of: MongoDBCollectionDDL.idField)
    }

    // MARK: - Public API

    /// The statements for a save, each naming the change it writes.
    ///
    /// A change the shell cannot carry as the value the grid shows is refused with the reason,
    /// never left out and never written as something else.
    func generateRowWrites(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []
        var deletions: [(rowIndex: Int, identity: String)] = []

        for change in changes {
            do {
                switch change.type {
                case .insert:
                    guard insertedRowIndices.contains(change.rowIndex) else { continue }
                    let statement = try insertStatement(for: change, insertedRowData: insertedRowData)
                    writes.append(PluginRowWrite(statement: statement, rowIndices: [change.rowIndex]))
                case .update:
                    guard let statement = try updateStatement(for: change) else { continue }
                    writes.append(PluginRowWrite(statement: statement, rowIndices: [change.rowIndex]))
                case .delete:
                    guard deletedRowIndices.contains(change.rowIndex) else { continue }
                    deletions.append((rowIndex: change.rowIndex, identity: try identityJson(of: change)))
                }
            } catch let refusal as MongoDBWriteRefusal {
                throw refusal.refusal(ofRow: change.rowIndex)
            }
        }

        if let deletion = deleteWrite(for: deletions) {
            writes.append(deletion)
        }
        return writes
    }

    // MARK: - INSERT

    /// NULL and DEFAULT leave a field out of a new document. A row with nothing else in it is the
    /// empty document, which the server stores with a generated `_id`.
    private func insertStatement(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> String {
        let cells: [(field: String, value: PluginCellValue)]
        if let values = insertedRowData[change.rowIndex] {
            cells = zip(columns, values).map { (field: $0, value: $1) }
        } else {
            cells = change.cellChanges.map { (field: $0.columnName, value: $0.newValue) }
        }
        let entries = try cells.filter { !isLeftOut($0.value) }.map { cell in
            "\(quotedKey(cell.field)): \(try documentValueJson(cell.value, field: cell.field))"
        }
        return "\(collectionAccessor).insertOne({\(entries.joined(separator: ", "))})"
    }

    private func isLeftOut(_ value: PluginCellValue) -> Bool {
        value.isNull || value.asText == Self.defaultMarker
    }

    /// A value of a whole document the grid writes: a new row, a duplicate or a paste, or a
    /// deleted document put back. An `_id` the row holds is kept, typed the way the filters type it;
    /// the grid leaves a new row's `_id` as DEFAULT, so the server generates it.
    private func documentValueJson(_ value: PluginCellValue, field: String) throws -> String {
        if field == MongoDBCollectionDDL.idField {
            return try idValueJson(value)
        }
        guard !field.isEmpty, field != "__proto__" else {
            throw MongoDBWriteRefusal.unwritableFieldName(field: field)
        }
        return try valueJson(value, field: field, replacing: nil)
    }

    // MARK: - Restore

    /// Puts a deleted document back with the `_id` it had.
    ///
    /// A new row leaves `_id` to the server. Undoing a delete is the opposite requirement: a new
    /// `_id` is a different document, and anything that referenced the old one still points at
    /// nothing. A value that cannot be written refuses the restore rather than dropping the field.
    func generateRestore(rows: [[PluginCellValue]]) -> [(statement: String, parameters: [PluginCellValue])]? {
        guard let idIndex = idColumnIndex else { return nil }

        do {
            return try rows.map { row in
                guard idIndex < row.count else { throw MongoDBWriteRefusal.missingIdentity }
                var entries = ["\"_id\": \(try idValueJson(row[idIndex]))"]
                for (index, value) in row.enumerated() where index != idIndex && index < columns.count {
                    guard !isLeftOut(value) else { continue }
                    let field = columns[index]
                    entries.append("\(quotedKey(field)): \(try documentValueJson(value, field: field))")
                }
                let statement = "\(collectionAccessor).insertOne({\(entries.joined(separator: ", "))})"
                return (statement: statement, parameters: [])
            }
        } catch let refusal as MongoDBWriteRefusal {
            Self.logger.warning(
                "Refusing to restore into '\(self.collectionName, privacy: .private)': \(refusal.reason, privacy: .public)"
            )
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - UPDATE

    private enum CellWrite {
        case remove(field: String)
        case whole(field: String, json: String)
        case nested(field: String, changes: [MongoNestedValueDiff.Change], edited: MongoDocumentText.Value)

        var field: String {
            switch self {
            case .remove(let field), .whole(let field, _), .nested(let field, _, _): return field
            }
        }
    }

    private func updateStatement(for change: PluginRowChange) throws -> String? {
        guard !change.cellChanges.isEmpty else { return nil }
        let identity = try identityJson(of: change)
        let cellWrites = try change.cellChanges.map {
            try cellWrite(field: $0.columnName, from: $0.oldValue, to: $0.newValue)
        }
        let update = try updateDocument(for: cellWrites)
        return "\(collectionAccessor).updateOne({\"_id\": \(identity)}, \(update))"
    }

    private func cellWrite(field: String, from oldValue: PluginCellValue, to newValue: PluginCellValue) throws -> CellWrite {
        guard field != MongoDBCollectionDDL.idField else { throw MongoDBWriteRefusal.identityChanged }
        switch newValue {
        case .null:
            return .remove(field: field)
        case .bytes(let data):
            return .whole(field: field, json: try binaryJson(data, field: field, replacing: oldValue))
        case .text(let text):
            guard text != Self.defaultMarker else { throw MongoDBWriteRefusal.noDefaultValue(field: field) }
            if let nested = try nestedEdit(of: field, from: oldValue, to: text) {
                return nested
            }
            return .whole(field: field, json: try valueJson(newValue, field: field, replacing: oldValue))
        }
    }

    /// An edit of a nested document or array, as the paths it changed.
    ///
    /// Nil when the cell does not hold a complete one on both sides, and the edit is then written
    /// whole. An old value shortened for display cannot be diffed, but a complete value typed over
    /// it replaces the field without needing it; new text that is still shortened is refused when
    /// it is written.
    private func nestedEdit(of field: String, from oldValue: PluginCellValue, to text: String) throws -> CellWrite? {
        guard isContainerKind(field), case .text(let oldText) = oldValue, opensContainer(text),
              !JSONTruncation.isIncompleteStructure(text), !JSONTruncation.isIncompleteStructure(oldText),
              let old = try? MongoDocumentText.Value(parsing: oldText), old.isContainer else {
            return nil
        }
        guard let edited = try? MongoDocumentText.Value(parsing: text), edited.isContainer else {
            throw MongoDBWriteRefusal.unreadableJSON(field: field)
        }
        let changes = MongoNestedValueDiff.changes(from: old, to: edited, at: field)
        return .nested(field: field, changes: changes, edited: edited)
    }

    /// A classic update when every field can be named by a path, otherwise a pipeline that writes
    /// each changed field whole.
    private func updateDocument(for cellWrites: [CellWrite]) throws -> String {
        if let special = cellWrites.first(where: { MongoDBUpdateDocument.needsFieldExpression($0.field) }) {
            guard capabilities().supportsFieldExpressions != false else {
                throw MongoDBWriteRefusal.fieldNeedsMongoDB5(field: special.field)
            }
            return MongoDBUpdateDocument.pipeline(try cellWrites.map(wholeFieldWrite))
        }

        var sets: [(path: String, json: String)] = []
        var removals: [String] = []
        for cellWrite in cellWrites {
            switch cellWrite {
            case .remove(let field):
                removals.append(field)
            case .whole(let field, let json):
                sets.append((path: field, json: json))
            case .nested(let field, let changes, let edited):
                guard !changes.isEmpty else {
                    sets.append((path: field, json: try shellJson(edited, field: field)))
                    continue
                }
                for change in changes {
                    switch change {
                    case .set(let path, let value):
                        sets.append((path: path, json: try shellJson(value, field: field)))
                    case .remove(let path):
                        removals.append(path)
                    }
                }
            }
        }
        return MongoDBUpdateDocument.classic(sets: sets, removals: removals)
    }

    private func wholeFieldWrite(_ cellWrite: CellWrite) throws -> MongoDBUpdateDocument.FieldWrite {
        switch cellWrite {
        case .remove(let field):
            return .remove(field: field)
        case .whole(let field, let json):
            return .set(field: field, json: json)
        case .nested(let field, _, let edited):
            return .set(field: field, json: try shellJson(edited, field: field))
        }
    }

    // MARK: - DELETE

    /// One `deleteMany` over every `_id` when several rows go, which names each of them.
    private func deleteWrite(for deletions: [(rowIndex: Int, identity: String)]) -> PluginRowWrite? {
        guard let only = deletions.first else { return nil }
        let rowIndices = deletions.map(\.rowIndex)
        guard deletions.count > 1 else {
            return PluginRowWrite(
                statement: "\(collectionAccessor).deleteOne({\"_id\": \(only.identity)})",
                rowIndices: rowIndices
            )
        }
        let inList = deletions.map(\.identity).joined(separator: ", ")
        return PluginRowWrite(
            statement: "\(collectionAccessor).deleteMany({\"_id\": {\"$in\": [\(inList)]}})",
            rowIndices: rowIndices
        )
    }

    // MARK: - Values

    private func identityJson(of change: PluginRowChange) throws -> String {
        guard let idIndex = idColumnIndex, let originalRow = change.originalRow, idIndex < originalRow.count else {
            throw MongoDBWriteRefusal.missingIdentity
        }
        return try idValueJson(originalRow[idIndex])
    }

    /// A cell's value as the JSON the statement carries.
    private func valueJson(_ value: PluginCellValue, field: String, replacing oldValue: PluginCellValue?) throws -> String {
        switch value {
        case .null:
            return "null"
        case .bytes(let data):
            return try binaryJson(data, field: field, replacing: oldValue)
        case .text(let text):
            if case .bytes(let oldData) = oldValue {
                return try textIntoBinaryJson(text, field: field, replacing: oldData)
            }
            guard !JSONTruncation.isIncompleteStructure(text) else {
                throw MongoDBWriteRefusal.truncatedValue(field: field)
            }
            return try jsonValue(for: text, field: field)
        }
    }

    private func binaryJson(_ data: Data, field: String, replacing oldValue: PluginCellValue?) throws -> String {
        let subtype = try binarySubtype(of: data, field: field, replacing: oldValue)
        return MongoDBUuidCodec.extendedJson(for: MongoDBBinaryValue(data: data, subtype: subtype))
    }

    /// Edited bytes keep the subtype of the value they replace. Copied bytes keep the subtype they
    /// were read with. Bytes with neither are generic binary only where the validator declares the
    /// field binary; anywhere else the subtype is unknown and the write is refused.
    private func binarySubtype(of data: Data, field: String, replacing oldValue: PluginCellValue?) throws -> UInt8 {
        if case .bytes(let oldData) = oldValue {
            return try onlySubtype(binarySubtypes.subtypes(of: oldData, in: field), field: field)
        }
        let known = binarySubtypes.subtypes(of: data, in: field)
        if known.isEmpty, declaredBinaryFields.contains(field) {
            return 0
        }
        return try onlySubtype(known, field: field)
    }

    private func onlySubtype(_ subtypes: Set<UInt8>, field: String) throws -> UInt8 {
        guard subtypes.count == 1, let only = subtypes.first else {
            throw MongoDBWriteRefusal.binarySubtypeUnknown(field: field)
        }
        return only
    }

    /// Text typed over a binary value is a UUID in one of its wrappers, or nothing at all. Any other
    /// text would turn the field into a string.
    private func textIntoBinaryJson(_ text: String, field: String, replacing oldData: Data) throws -> String {
        if let wrapped = MongoDBUuidCodec.extendedJsonFromWrapper(text) {
            return wrapped
        }
        guard text.isEmpty else { throw MongoDBWriteRefusal.binaryNeedsBytes(field: field) }
        return try binaryJson(Data(), field: field, replacing: .bytes(oldData))
    }

    private func shellJson(_ value: MongoDocumentText.Value, field: String) throws -> String {
        try MongoExtendedJsonForm.shellValue(value, field: field).compactText
    }

    private func isContainerKind(_ field: String) -> Bool {
        let kind = kind(of: field)
        return kind == .document || kind == .array
    }

    private func opensContainer(_ text: String) -> Bool {
        text.hasPrefix("{") || text.hasPrefix("[")
    }

    private func quotedKey(_ field: String) -> String {
        "\"\(escapeJsonString(field))\""
    }

    // MARK: - Identity

    /// An `_id` held as bytes filters on binary with the subtype it was read with, or the one every
    /// sampled `_id` shares.
    private func idValueJson(_ value: PluginCellValue) throws -> String {
        let idField = MongoDBCollectionDDL.idField
        switch value {
        case .null:
            throw MongoDBWriteRefusal.missingIdentity
        case .bytes(let data):
            let known = binarySubtypes.subtypes(of: data, in: idField)
            if known.isEmpty, case .binary(let subtype) = identityKind {
                return MongoDBUuidCodec.extendedJson(for: MongoDBBinaryValue(data: data, subtype: subtype))
            }
            let subtype = try onlySubtype(known, field: idField)
            return MongoDBUuidCodec.extendedJson(for: MongoDBBinaryValue(data: data, subtype: subtype))
        case .text(let text):
            if let document = try documentIdJson(text) {
                return document
            }
            return idValueJson(text)
        }
    }

    /// An embedded document compares field by field in order, so a document `_id` has to be sent in
    /// the order it is stored, which is the order the grid now shows.
    private func documentIdJson(_ text: String) throws -> String? {
        guard (declaredKinds[MongoDBCollectionDDL.idField] ?? identityKind) == .document,
              let parsed = try? MongoDocumentText.Value(parsing: text), case .object = parsed else {
            return nil
        }
        return try shellJson(parsed, field: MongoDBCollectionDDL.idField)
    }

    /// An `_id` is matched by value and type together, so a string `_id` of `1001` written as a
    /// number matches no document. The column's own kind decides when it is known; the text's
    /// shape is only the fallback.
    private func idValueJson(_ idValue: String) -> String {
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(idValue) {
            return binary
        }
        let idKind = declaredKinds["_id"] ?? identityKind
        switch idKind {
        case .string:
            return "\"\(escapeJsonString(idValue))\""
        case .objectId, .int32, .int64, .double, .decimal128, .date:
            if let typed = typedJson(idValue, kind: idKind) { return typed }
        case .boolean:
            if idValue == "true" || idValue == "false" { return idValue }
        default:
            break
        }
        if isObjectIdString(idValue) {
            return "{\"$oid\": \"\(idValue)\"}"
        }
        if Int64(idValue) != nil {
            return integerJson(idValue)
        }
        return "\"\(escapeJsonString(idValue))\""
    }

    private func kind(of field: String) -> BsonValueKind? {
        declaredKinds[field] ?? columnKinds[field]
    }

    /// Check if a string looks like a MongoDB ObjectId (24 hex characters)
    private func isObjectIdString(_ value: String) -> Bool {
        let nsValue = value as NSString
        return nsValue.length == 24 && value.allSatisfy { $0.isHexDigit }
    }

    /// A cell's text as the value it stands for, in the field's type when that type is known.
    ///
    /// The statement is JavaScript the shell evaluates, so text is only ever pasted in when it is
    /// strict JSON. A stored string that merely starts with `[` and ends with `]` would otherwise run
    /// as code the moment its row is duplicated or its delete is undone.
    private func jsonValue(for value: String, field: String) throws -> String {
        if declaredKinds[field] == .string {
            return "\"\(escapeJsonString(value))\""
        }
        if value == "true" || value == "false" || value == "null" {
            return value
        }
        if let typed = typedJson(value, kind: kind(of: field)) {
            return typed
        }
        if MongoDBJsonNumber.isValid(value) {
            return Int64(value) != nil ? integerJson(value) : value
        }
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(value) {
            return binary
        }
        if let container = try containerJson(value, field: field) {
            return container
        }
        return "\"\(escapeJsonString(value))\""
    }

    /// A bare JSON number is stored as int32 or double, which silently retypes a column that
    /// holds int64 or decimal128, and a date or an ObjectId written as its text is a string.
    /// Extended JSON is the only way to keep the original type.
    private func typedJson(_ value: String, kind: BsonValueKind?) -> String? {
        switch kind {
        case .date:
            return MongoDBFilterValue.writableDateJson(value)
        case .objectId:
            return MongoDBFilterValue.objectIdJson(value)
        case .decimal128:
            guard NumberText.isJSONNumberLiteral(value) else { return nil }
            return "{\"$numberDecimal\": \"\(escapeJsonString(value))\"}"
        case .int64:
            guard Int64(value) != nil else { return nil }
            return "{\"$numberLong\": \"\(escapeJsonString(value))\"}"
        case .double:
            guard MongoDBJsonNumber.isValid(value), let parsed = Double(value), parsed.isFinite else { return nil }
            return "{\"$numberDouble\": \"\(escapeJsonString(value))\"}"
        case .int32:
            guard let parsed = Int32(value) else { return nil }
            return String(parsed)
        default:
            return nil
        }
    }

    /// JavaScript numbers are doubles, so an integer past 2^53 written bare reaches the server
    /// already rounded.
    private func integerJson(_ value: String) -> String {
        guard let parsed = Int64(value), parsed.magnitude > Self.largestExactDouble else { return value }
        return "{\"$numberLong\": \"\(value)\"}"
    }

    private static let largestExactDouble: UInt64 = 1 << 53

    /// A nested document or array, spelled so the shell stores the types its text shows. Text that
    /// only looks like one is a string, except in a field that holds documents or arrays, where it
    /// is refused rather than stored as a string.
    private func containerJson(_ value: String, field: String) throws -> String? {
        guard opensContainer(value) else { return nil }
        guard value.hasSuffix("}") || value.hasSuffix("]"),
              let parsed = try? MongoDocumentText.Value(parsing: value), parsed.isContainer else {
            if isContainerKind(field) { throw MongoDBWriteRefusal.unreadableJSON(field: field) }
            return nil
        }
        return try shellJson(parsed, field: field)
    }

    /// Escape special characters for JSON strings (handles Unicode control chars U+0000-U+001F)
    private func escapeJsonString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity((value as NSString).length)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
