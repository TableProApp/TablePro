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
    /// Every kind each field held in the documents read, which says whether a cell showing `{` or
    /// `[` holds a document or an array or a string that reads the same.
    var fieldKinds: MongoDBFieldKinds = .empty

    /// The subtype of each binary value the grid shows, so bytes written back keep the subtype they
    /// were read with.
    var binarySubtypes: MongoDBBinarySubtypes = .empty
    /// Fields the validator declares as binary. Bytes typed into a new document there are generic
    /// binary, subtype 0, which is also what the column's `BLOB` type name says.
    var declaredBinaryFields: Set<String> = []
    /// Asked only for a row that needs `$setField`, since reading the version can wait on the
    /// connection.
    var capabilities: () -> MongoDBCapabilities = { .unknown }

    private static let defaultMarker = "__DEFAULT__"

    /// Where a value written whole comes from. A cell carries only text or bytes, so this is all the
    /// generator knows about the type the value has to keep.
    private enum Provenance {
        /// A cell of an existing document, edited from the value it held. Data Rewind puts a value
        /// back the same way, so an edit is never taken to be something the user typed.
        case edit(replacing: PluginCellValue)
        /// A cell of a new document that the user filled in.
        case typedIntoNewDocument
        /// A cell of a new document copied from another row, as a duplicate or a paste does.
        case copiedIntoNewDocument
        /// A value of a deleted document, put back as it was read.
        case restored

        var replaced: PluginCellValue? {
            guard case .edit(let value) = self else { return nil }
            return value
        }
    }

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
    ///
    /// A new row's change lists the cells the user filled in; every other value came with the row,
    /// copied from the row it duplicates or pastes.
    private func insertStatement(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> String {
        let filledIn = change.cellChanges.map { (field: $0.columnName, value: $0.newValue) }
        let typed = Dictionary(filledIn.map { ($0.field, $0.value) }, uniquingKeysWith: { _, last in last })
        let cells: [(field: String, value: PluginCellValue)]
        if let values = insertedRowData[change.rowIndex] {
            cells = zip(columns, values).map { (field: $0, value: $1) }
        } else {
            cells = filledIn
        }
        let entries = try cells.filter { !isLeftOut($0.value) }.map { cell in
            let provenance: Provenance = typed[cell.field] == cell.value ? .typedIntoNewDocument : .copiedIntoNewDocument
            return "\(quotedKey(cell.field)): \(try documentValueJson(cell.value, field: cell.field, provenance: provenance))"
        }
        return "\(collectionAccessor).insertOne({\(entries.joined(separator: ", "))})"
    }

    private func isLeftOut(_ value: PluginCellValue) -> Bool {
        value.isNull || value.asText == Self.defaultMarker
    }

    /// A value of a whole document the grid writes: a new row, a duplicate or a paste, or a
    /// deleted document put back. An `_id` the row holds is kept, typed the way the filters type it;
    /// the grid leaves a new row's `_id` as DEFAULT, so the server generates it.
    ///
    /// The shell inserts through libmongoc, which refuses a document holding an empty key at any
    /// depth, and a JavaScript object reads `__proto__` as its prototype and drops it. An update
    /// carries both, so only a new document refuses them, before anything in the save is sent.
    private func documentValueJson(_ value: PluginCellValue, field: String, provenance: Provenance) throws -> String {
        guard !field.isEmpty else { throw MongoDBWriteRefusal.emptyFieldNameInNewDocument }
        guard field != "__proto__" else { throw MongoDBWriteRefusal.prototypeFieldInNewDocument }
        let json = field == MongoDBCollectionDDL.idField
            ? try idValueJson(value)
            : try valueJson(value, field: field, provenance: provenance)
        if opensContainer(json), case .text(let text) = value, parsedContainer(text)?.holdsEmptyKey == true {
            throw MongoDBWriteRefusal.emptyKeyInNewDocument(field: field)
        }
        return json
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
                let idField = MongoDBCollectionDDL.idField
                var entries = ["\(quotedKey(idField)): \(try documentValueJson(row[idIndex], field: idField, provenance: .restored))"]
                for (index, value) in row.enumerated() where index != idIndex && index < columns.count {
                    guard !isLeftOut(value) else { continue }
                    let field = columns[index]
                    entries.append("\(quotedKey(field)): \(try documentValueJson(value, field: field, provenance: .restored))")
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
            return .whole(field: field, json: try binaryJson(data, field: field, provenance: .edit(replacing: oldValue)))
        case .text(let text):
            guard text != Self.defaultMarker else { throw MongoDBWriteRefusal.noDefaultValue(field: field) }
            if let nested = try nestedEdit(of: field, from: oldValue, to: text) {
                return nested
            }
            return .whole(field: field, json: try valueJson(newValue, field: field, provenance: .edit(replacing: oldValue)))
        }
    }

    /// An edit of a nested document or array, as the paths it changed.
    ///
    /// Nil when the cell is not known to hold a complete one, and the edit is then written whole. A
    /// path into a string is refused by the server, so a field that also held strings is never
    /// diffed, whatever most of its rows hold. An old value shortened for display cannot be diffed,
    /// but a complete value typed over it replaces the field without needing it; new text that is
    /// still shortened is refused when it is written.
    private func nestedEdit(of field: String, from oldValue: PluginCellValue, to text: String) throws -> CellWrite? {
        guard opensContainer(text), !JSONTruncation.isIncompleteStructure(text),
              holdsContainer(oldValue, field: field), case .text(let oldText) = oldValue,
              !JSONTruncation.isIncompleteStructure(oldText), let old = parsedContainer(oldText) else {
            return nil
        }
        guard let edited = parsedContainer(text) else {
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
    private func valueJson(_ value: PluginCellValue, field: String, provenance: Provenance) throws -> String {
        switch value {
        case .null:
            return "null"
        case .bytes(let data):
            return try binaryJson(data, field: field, provenance: provenance)
        case .text(let text):
            if case .edit(replacing: .bytes(let oldData)) = provenance {
                return try textIntoBinaryJson(text, field: field, replacing: oldData)
            }
            guard !JSONTruncation.isIncompleteStructure(text) else {
                throw MongoDBWriteRefusal.truncatedValue(field: field)
            }
            return try jsonValue(for: text, field: field, provenance: provenance)
        }
    }

    private func binaryJson(_ data: Data, field: String, provenance: Provenance) throws -> String {
        let subtype = try binarySubtype(of: data, field: field, provenance: provenance)
        return MongoDBUuidCodec.extendedJson(for: MongoDBBinaryValue(data: data, subtype: subtype))
    }

    /// Edited bytes keep the subtype of the value they replace, and any other bytes the subtype
    /// they were read with. A subtype nothing recorded is never assumed: a restore after a relaunch
    /// hands back bytes alone, and so does an edit over a value that was not binary, which is how
    /// Data Rewind puts bytes back. Only bytes the user typed into a new document are new, and they
    /// are generic binary where the validator declares the field binary.
    private func binarySubtype(of data: Data, field: String, provenance: Provenance) throws -> UInt8 {
        if case .edit(replacing: .bytes(let oldData)) = provenance {
            return try onlySubtype(binarySubtypes.subtypes(of: oldData, in: field), field: field)
        }
        let known = binarySubtypes.subtypes(of: data, in: field)
        if known.isEmpty, case .typedIntoNewDocument = provenance, declaredBinaryFields.contains(field) {
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
        return try binaryJson(Data(), field: field, provenance: .edit(replacing: .bytes(oldData)))
    }

    private func shellJson(_ value: MongoDocumentText.Value, field: String) throws -> String {
        try MongoExtendedJsonForm.shellValue(value, field: field).compactText
    }

    private func opensContainer(_ text: String) -> Bool {
        text.hasPrefix("{") || text.hasPrefix("[")
    }

    private func parsedContainer(_ text: String) -> MongoDocumentText.Value? {
        guard let parsed = try? MongoDocumentText.Value(parsing: text), parsed.isContainer else { return nil }
        return parsed
    }

    private func quotedKey(_ field: String) -> String {
        "\"\(escapeJsonString(field))\""
    }

    // MARK: - Identity

    /// An `_id` held as bytes filters on binary with the subtype it was read with. The same bytes
    /// under another subtype are another `_id`, which may name another document, so a subtype that
    /// was not read for these bytes is never borrowed from the other rows.
    private func idValueJson(_ value: PluginCellValue) throws -> String {
        switch value {
        case .null:
            throw MongoDBWriteRefusal.missingIdentity
        case .bytes(let data):
            let subtypes = binarySubtypes.subtypes(of: data, in: MongoDBCollectionDDL.idField)
            guard subtypes.count == 1, let subtype = subtypes.first else {
                throw MongoDBWriteRefusal.identitySubtypeUnknown
            }
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
    private func jsonValue(for value: String, field: String, provenance: Provenance) throws -> String {
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
        if let container = try containerJson(value, field: field, provenance: provenance) {
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

    /// A nested document or array, spelled so the shell stores the types its text shows, or nil for
    /// text that is written as a string.
    private func containerJson(_ value: String, field: String, provenance: Provenance) throws -> String? {
        guard opensContainer(value) else { return nil }
        let parsed = value.hasSuffix("}") || value.hasSuffix("]") ? parsedContainer(value) : nil
        switch containerReading(of: field, isJSON: parsed != nil, provenance: provenance) {
        case .container:
            guard let parsed else { throw MongoDBWriteRefusal.unreadableJSON(field: field) }
            return try shellJson(parsed, field: field)
        case .jsonOrString:
            return try parsed.map { try shellJson($0, field: field) }
        case .ambiguous:
            throw MongoDBWriteRefusal.documentOrText(field: field)
        }
    }

    // MARK: - Documents and arrays

    /// What text opening with `{` or `[` is written as.
    private enum ContainerReading {
        /// A document or an array, and text that is not JSON is refused rather than stored as a string.
        case container
        /// JSON is a document or an array, and any other text a string.
        case jsonOrString
        /// The field holds both, and nothing says which this value is meant to be.
        case ambiguous
    }

    /// A cell that held a document or an array stays one. Otherwise the kinds the field held decide:
    /// JSON is a document or an array where the field held those and no strings, and could be either
    /// where it held both, which is refused. Text that is not JSON can only be a string when it was
    /// read from a cell, where a document always shows as JSON, or typed over a value that was not
    /// one. An existing value whose field was never read says nothing either way.
    private func containerReading(of field: String, isJSON: Bool, provenance: Provenance) -> ContainerReading {
        if let replaced = provenance.replaced, holdsContainer(replaced, field: field) {
            return .container
        }
        guard let held = heldKinds(of: field) else {
            return isJSON && standsForUnreadValue(provenance) ? .ambiguous : .jsonOrString
        }
        guard held.contains(.document) || held.contains(.array) else { return .jsonOrString }
        guard held.contains(.string) else { return .container }
        return !isJSON && nonJSONCanOnlyBeText(provenance) ? .jsonOrString : .ambiguous
    }

    /// Whether a cell holds a document or an array: text of that shape, in a field that held that
    /// shape and no strings, since a string can read the same.
    private func holdsContainer(_ value: PluginCellValue, field: String) -> Bool {
        guard case .text(let text) = value, opensContainer(text), let held = heldKinds(of: field) else { return false }
        let shape: BsonValueKind = text.hasPrefix("[") ? .array : .document
        return held.contains(shape) && !held.contains(.string)
    }

    private func nonJSONCanOnlyBeText(_ provenance: Provenance) -> Bool {
        switch provenance {
        case .restored, .copiedIntoNewDocument:
            return true
        case .edit(let replaced):
            return holdsOtherThanContainer(replaced)
        case .typedIntoNewDocument:
            return false
        }
    }

    /// Whether a cell is known to hold something other than a document or an array: text that does
    /// not open one, or opens one and is not JSON, which only a string can be.
    private func holdsOtherThanContainer(_ value: PluginCellValue) -> Bool {
        switch value {
        case .null:
            return false
        case .bytes:
            return true
        case .text(let text):
            guard opensContainer(text) else { return true }
            return !JSONTruncation.isIncompleteStructure(text) && parsedContainer(text) == nil
        }
    }

    /// A value a document already holds that reads like a document or an array: one put back, or
    /// the one an edit replaces.
    private func standsForUnreadValue(_ provenance: Provenance) -> Bool {
        switch provenance {
        case .restored:
            return true
        case .edit(replacing: .text(let text)):
            return opensContainer(text)
        case .edit, .typedIntoNewDocument, .copiedIntoNewDocument:
            return false
        }
    }

    /// The validator's kind where it declares one, which the server enforces, otherwise every kind
    /// the documents read held.
    private func heldKinds(of field: String) -> Set<BsonValueKind>? {
        if let declared = declaredKinds[field] { return [declared] }
        return fieldKinds.kinds(of: field)
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
