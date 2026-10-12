import Foundation
import TableProFirebaseCore
import TableProPluginKit

extension FirebasePluginDriver {
    // MARK: - Grid edits

    /// Each change becomes one request line, the same text the console takes, so the history shows
    /// exactly what was sent. An edit is typed by the value it replaces.
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try changes.compactMap { change in
            do {
                let request: FirebaseRequest?
                switch variant {
                case .firestore:
                    request = try firestoreRequest(for: change, table: table, columns: columns, insertedRowData: insertedRowData)
                case .realtimeDatabase:
                    request = try databaseRequest(for: change, table: table, columns: columns, insertedRowData: insertedRowData)
                }
                return request.map { PluginRowWrite(statement: $0.text, rowIndices: [change.rowIndex]) }
            } catch let refusal as PluginRowWriteRefusal {
                throw refusal
            } catch {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: error.localizedDescription)
            }
        }
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let statements = rows.enumerated().compactMap { index, row -> String? in
            let change = PluginRowChange(rowIndex: index, type: .insert, cellChanges: [], originalRow: nil)
            switch variant {
            case .firestore:
                return (try? firestoreRequest(for: change, table: table, columns: columns, insertedRowData: [index: row]))??.text
            case .realtimeDatabase:
                return (try? databaseRequest(for: change, table: table, columns: columns, insertedRowData: [index: row]))??.text
            }
        }
        return statements.count == rows.count ? statements.map { ($0, []) } : nil
    }

    private func firestoreRequest(
        for change: PluginRowChange,
        table: String,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> FirebaseRequest? {
        let target = try FirestoreCollectionTarget(table: table)
        let nameColumn = FirestoreQueryBuilder.nameField
        switch change.type {
        case .insert:
            let row = insertedRowData[change.rowIndex] ?? []
            let absent = change.absentColumns ?? []
            var fields: [String: FirestoreValue] = [:]
            var name: String?
            for (index, column) in columns.enumerated() where index < row.count && !absent.contains(index) {
                if column == nameColumn {
                    name = row[index].asText.flatMap { $0.isEmpty ? nil : $0 }
                    continue
                }
                guard let value = try firestoreValue(row[index], type: columnType(table, column)) else { continue }
                fields[column] = value
            }
            if target.isGroup {
                guard let name, FirestorePath.isDocument(name) else {
                    throw FirebaseError.configuration(String(
                        localized: "A new row in a collection group needs __name__ set to the full document path, such as users/alice/orders/1."
                    ))
                }
                let split = FirestorePath.split(collectionPath: name)
                return FirebaseRequest(method: .post, path: split.parent,
                                       query: [URLQueryItem(name: "documentId", value: FirestorePath.lastSegment(name))],
                                       body: FirebaseJSON.object(fields.mapValues(FirestoreDocumentJSON.json)).text())
            }
            let collection = target.parentPath.isEmpty ? target.collectionId : target.parentPath + "/" + target.collectionId
            return FirebaseRequest(method: .post, path: collection,
                                   query: name.map { [URLQueryItem(name: "documentId", value: $0)] } ?? [],
                                   body: FirebaseJSON.object(fields.mapValues(FirestoreDocumentJSON.json)).text())
        case .update:
            let path = try documentPath(change, columns: columns, target: target)
            var fields: [String: FirestoreValue] = [:]
            var mask: [String] = []
            let absent = change.absentColumns ?? []
            for cell in change.cellChanges where cell.columnName != nameColumn {
                mask.append(cell.columnName)
                if absent.contains(cell.columnIndex) { continue }
                let type = cellType(locator: path, table: table, column: cell.columnName)
                fields[cell.columnName] = try firestoreValue(cell.newValue, type: type) ?? .null
            }
            for index in absent where index < columns.count && !mask.contains(columns[index]) && columns[index] != nameColumn {
                mask.append(columns[index])
            }
            guard !mask.isEmpty else { return nil }
            return FirebaseRequest(method: .patch, path: path,
                                   query: [URLQueryItem(name: "updateMask", value: mask.joined(separator: ","))],
                                   body: FirebaseJSON.object(fields.mapValues(FirestoreDocumentJSON.json)).text())
        case .delete:
            return FirebaseRequest(method: .delete, path: try documentPath(change, columns: columns, target: target))
        }
    }

    private func firestoreValue(_ cell: PluginCellValue, type: String?) throws -> FirestoreValue? {
        switch cell {
        case .null:
            return .null
        case .bytes(let data):
            return .bytes(data)
        case .text(let text):
            return try FirestoreCell.value(text: text, typeName: type)
        }
    }

    private func documentPath(_ change: PluginRowChange, columns: [String], target: FirestoreCollectionTarget) throws -> String {
        guard let index = columns.firstIndex(of: FirestoreQueryBuilder.nameField),
              let row = change.originalRow, index < row.count, let name = row[index].asText, !name.isEmpty else {
            throw FirebaseError.configuration(String(localized: "The row has no __name__, so the document it came from is unknown. Reload the collection."))
        }
        return target.documentPath(forRowName: name)
    }

    private func databaseRequest(
        for change: PluginRowChange,
        table: String,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> FirebaseRequest? {
        let node = Self.nodePath(table)
        let keyColumn = FirebaseColumns.key
        let valueColumn = FirebaseColumns.value
        switch change.type {
        case .insert:
            let row = insertedRowData[change.rowIndex] ?? []
            let absent = change.absentColumns ?? []
            var members: [String: FirebaseJSON] = [:]
            var plain: FirebaseJSON?
            var key: String?
            for (index, column) in columns.enumerated() where index < row.count && !absent.contains(index) {
                guard let text = row[index].asText else { continue }
                switch column {
                case keyColumn:
                    key = text.isEmpty ? nil : text
                case valueColumn:
                    plain = try RealtimeDatabaseCell.value(text: text, typeName: columnType(table, column))
                default:
                    members[column] = try RealtimeDatabaseCell.value(text: text, typeName: columnType(table, column))
                }
            }
            let value = members.isEmpty ? (plain ?? .null) : .object(members)
            guard value != .null else {
                throw FirebaseError.configuration(String(localized: "A new child needs at least one value. The Realtime Database does not store empty nodes."))
            }
            if let key {
                try RealtimeDatabasePath.validateKey(key)
                return FirebaseRequest(method: .put, path: RealtimeDatabasePath.join(node, key), body: value.text())
            }
            return FirebaseRequest(method: .post, path: node, body: value.text())
        case .update:
            let locator = try databaseLocator(change, columns: columns, node: node)
            let absent = change.absentColumns ?? []
            var members: [String: FirebaseJSON] = [:]
            for cell in change.cellChanges where cell.columnName != keyColumn {
                if cell.columnName == valueColumn {
                    let type = cellType(locator: locator, table: table, column: valueColumn)
                    let value = try cell.newValue.asText.map { try RealtimeDatabaseCell.value(text: $0, typeName: type) } ?? .null
                    return FirebaseRequest(method: .put, path: locator, body: value.text())
                }
                if absent.contains(cell.columnIndex) {
                    members[cell.columnName] = .null
                    continue
                }
                let type = cellType(locator: locator, table: table, column: cell.columnName)
                members[cell.columnName] = try cell.newValue.asText.map { try RealtimeDatabaseCell.value(text: $0, typeName: type) } ?? .null
            }
            for index in absent where index < columns.count && columns[index] != keyColumn && members[columns[index]] == nil {
                members[columns[index]] = .null
            }
            guard !members.isEmpty else { return nil }
            for key in members.keys { try RealtimeDatabasePath.validateKey(key) }
            return FirebaseRequest(method: .patch, path: locator, body: FirebaseJSON.object(members).text())
        case .delete:
            return FirebaseRequest(method: .delete, path: try databaseLocator(change, columns: columns, node: node))
        }
    }

    /// A node holding a plain value is shown as one row named after the node, and that row is the
    /// node itself rather than a child of it.
    private func databaseLocator(_ change: PluginRowChange, columns: [String], node: String) throws -> String {
        guard let index = columns.firstIndex(of: FirebaseColumns.key),
              let row = change.originalRow, index < row.count, let key = row[index].asText, !key.isEmpty else {
            throw FirebaseError.configuration(String(localized: "The row has no $key, so the node it came from is unknown. Reload the table."))
        }
        let child = RealtimeDatabasePath.join(node, key)
        if !knowsLocator(child), knowsLocator(node), RealtimeDatabasePath.lastSegment(node) == key {
            return node
        }
        return child
    }

    // MARK: - Whole documents

    static let unknownWriteMessage = String(localized: "This version of the Firebase driver cannot make that kind of document write. Update the plugin.")

    func documentWriteStatement(_ write: PluginDocumentWrite) throws -> String? {
        try documentRequest(write).text
    }

    func executeDocumentWrite(_ write: PluginDocumentWrite) async throws {
        switch variant {
        case .firestore:
            try await executeFirestoreDocumentWrite(write)
        case .realtimeDatabase:
            try await executeDatabaseDocumentWrite(write)
        }
    }

    func fetchDocument(table: String, schema: String?, locator: String) async throws -> String? {
        switch variant {
        case .firestore:
            guard let document = try await requireFirestore().getDocument(locator) else { return nil }
            return Self.documentText(path: document.path, fields: document.fields)
        case .realtimeDatabase:
            let value = try await requireRealtimeDatabase().get(locator)
            return value == .null ? nil : Self.nodeText(path: locator, value: value)
        }
    }

    /// The text an edit starts from carries the document's path under `__name__`, so the edit names
    /// the document it changes and a rename can be refused instead of written somewhere else.
    static func documentText(path: String, fields: [String: FirestoreValue]) -> String {
        var members = fields.mapValues(FirestoreDocumentJSON.json)
        members[FirestoreQueryBuilder.nameField] = .string(path)
        return FirebaseJSON.object(members).text(pretty: true)
    }

    static func nodeText(path: String, value: FirebaseJSON) -> String {
        FirebaseJSON.object([FirebaseColumns.key: .string(path), FirebaseColumns.value: value]).text(pretty: true)
    }

    private func documentRequest(_ write: PluginDocumentWrite) throws -> FirebaseRequest {
        switch variant {
        case .firestore:
            switch write.operation {
            case .insert(let text):
                let parsed = try Self.splitDocument(text)
                let target = try FirestoreCollectionTarget(table: write.table)
                if let path = parsed.path, path.contains("/") {
                    let split = FirestorePath.split(collectionPath: path)
                    return FirebaseRequest(method: .post, path: split.parent,
                                           query: [URLQueryItem(name: "documentId", value: split.collectionId)], body: parsed.body)
                }
                guard !target.isGroup else {
                    throw FirebaseError.configuration(String(localized: "A document added to a collection group needs __name__ set to its full path."))
                }
                let collection = target.parentPath.isEmpty ? target.collectionId : target.parentPath + "/" + target.collectionId
                return FirebaseRequest(method: .post, path: collection,
                                       query: parsed.path.map { [URLQueryItem(name: "documentId", value: $0)] } ?? [], body: parsed.body)
            case .replace(let original, let edited):
                let before = try Self.splitDocument(original)
                let after = try Self.splitDocument(edited)
                guard let path = before.path else {
                    throw FirebaseError.configuration(String(localized: "The document lost its __name__. Reopen it."))
                }
                if let renamed = after.path, renamed != path {
                    throw FirebaseError.unsupported(String(localized: "A document cannot be renamed. Add a new document and delete this one."))
                }
                return FirebaseRequest(method: .patch, path: path, body: after.body)
            @unknown default:
                throw FirebaseError.unsupported(Self.unknownWriteMessage)
            }
        case .realtimeDatabase:
            switch write.operation {
            case .insert(let text):
                let parsed = try Self.splitNode(text)
                let node = Self.nodePath(write.table)
                if let key = parsed.key {
                    try RealtimeDatabasePath.validateKey(key)
                    return FirebaseRequest(method: .put, path: RealtimeDatabasePath.join(node, key), body: parsed.value.text())
                }
                return FirebaseRequest(method: .post, path: node, body: parsed.value.text())
            case .replace(let original, let edited):
                let before = try Self.splitNode(original)
                let after = try Self.splitNode(edited)
                guard let path = before.key else {
                    throw FirebaseError.configuration(String(localized: "The node lost its $key. Reopen it."))
                }
                if let renamed = after.key, renamed != path {
                    throw FirebaseError.unsupported(String(localized: "A node cannot be moved. Add it under the new key and delete this one."))
                }
                return FirebaseRequest(method: .put, path: path, body: after.value.text())
            @unknown default:
                throw FirebaseError.unsupported(Self.unknownWriteMessage)
            }
        }
    }

    private func executeFirestoreDocumentWrite(_ write: PluginDocumentWrite) async throws {
        let client = try requireFirestore()
        let request = try documentRequest(write)
        let fields = try FirestoreDocumentJSON.fields(from: request.body ?? "{}")
        switch write.operation {
        case .insert:
            _ = try await client.createDocument(collectionPath: request.path, documentId: request.queryValue("documentId"), fields: fields)
        case .replace(let original, _):
            let expected = try FirestoreDocumentJSON.fields(from: try Self.splitDocument(original).body)
            guard let current = try await client.getDocument(request.path) else {
                throw FirebaseError.precondition(String(localized: "The document was deleted after it was opened."))
            }
            guard Self.sameFields(current.fields, expected) else {
                throw FirebaseError.precondition(String(localized: "The document changed after it was opened. Reopen it and edit again."))
            }
            do {
                try await client.patchDocument(request.path, fields: fields, mask: nil, updateTime: current.updateTime)
            } catch FirebaseError.precondition {
                throw FirebaseError.precondition(String(localized: "The document changed after it was opened. Reopen it and edit again."))
            }
        @unknown default:
            throw FirebaseError.unsupported(Self.unknownWriteMessage)
        }
    }

    private func executeDatabaseDocumentWrite(_ write: PluginDocumentWrite) async throws {
        let client = try requireRealtimeDatabase()
        let request = try documentRequest(write)
        let value = try FirebaseJSON.parse(request.body ?? "null")
        switch write.operation {
        case .insert:
            if request.method == .post {
                _ = try await client.push(request.path, value: value)
            } else {
                try await client.put(request.path, value: value)
            }
        case .replace(let original, _):
            let expected = try Self.splitNode(original).value
            let current = try await client.getWithETag(request.path)
            guard current.value == expected else {
                throw FirebaseError.precondition(String(localized: "The node changed after it was opened. Reopen it and edit again."))
            }
            try await client.put(request.path, value: value, ifMatch: current.etag)
        @unknown default:
            throw FirebaseError.unsupported(Self.unknownWriteMessage)
        }
    }

    /// NaN never equals itself, so a document holding one would always look changed.
    static func sameFields(_ lhs: [String: FirestoreValue], _ rhs: [String: FirestoreValue]) -> Bool {
        FirebaseJSON.object(lhs.mapValues(FirestoreDocumentJSON.json)).text()
            == FirebaseJSON.object(rhs.mapValues(FirestoreDocumentJSON.json)).text()
    }

    static func splitDocument(_ text: String) throws -> (path: String?, body: String) {
        guard case .object(var members) = try FirebaseJSON.parse(text) else {
            throw FirebaseError.configuration(String(localized: "A Firestore document is a JSON object of fields."))
        }
        let name = members.removeValue(forKey: FirestoreQueryBuilder.nameField)
        if let name, name.stringValue == nil {
            throw FirebaseError.configuration(String(localized: "__name__ is the document's ID or path, as text."))
        }
        let path = name?.stringValue?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).nonEmptyPath
        return (path, FirebaseJSON.object(members).text())
    }

    /// A node is edited as `{"$key": "<path>", "$value": <JSON>}`; a new child may also be written
    /// as bare JSON, which is pushed under a generated key.
    static func splitNode(_ text: String) throws -> (key: String?, value: FirebaseJSON) {
        let json = try FirebaseJSON.parse(text)
        guard case .object(let members) = json, let value = members[FirebaseColumns.value],
              members.keys.allSatisfy({ $0 == FirebaseColumns.key || $0 == FirebaseColumns.value }) else {
            return (nil, json)
        }
        let key = members[FirebaseColumns.key]?.stringValue.map(RealtimeDatabasePath.normalized)?.nonEmptyPath
        return (key, value)
    }
}

private extension String {
    var nonEmptyPath: String? { isEmpty ? nil : self }
}
