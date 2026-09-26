//
//  ElasticsearchStatementGenerator.swift
//  ElasticsearchDriverPlugin
//
//  Converts tracked cell changes into tagged Elasticsearch REST mutations.
//

import Foundation
import TableProPluginKit

struct ElasticsearchWriteRequest: Equatable {
    let method: String
    let path: String
    let body: String?
}

struct ElasticsearchStatementGenerator {
    static let writeTag = "ELASTICSEARCH_WRITE:"
    private static let refreshQuery = "?refresh=true"

    let index: String
    let columns: [String]
    let columnTypeNames: [String]

    /// A `nested` column carries the whole array of objects, and its dotted leaves are views of
    /// those same bytes. Writing both makes Elasticsearch expand the dotted key into the object the
    /// array already fills, which it rejects as a mapping conflict, so the array is written once
    /// through its parent and a value typed into a leaf is refused rather than sent. Each leaf maps
    /// to the outermost array it belongs to, which is the column that writes it.
    private let nestedParentByLeaf: [String: String]

    init(index: String, columns: [String], columnTypeNames: [String]) {
        self.index = index
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.nestedParentByLeaf = Self.nestedParents(columns: columns, typeNames: columnTypeNames)
    }

    private static func nestedParents(columns: [String], typeNames: [String]) -> [String: String] {
        let parents = zip(columns, typeNames)
            .filter { $0.1 == ElasticsearchMappingFlattener.nestedTypeName }
            .map(\.0)
        guard !parents.isEmpty else { return [:] }
        var parentByLeaf: [String: String] = [:]
        for column in columns {
            let owners = parents.filter { column.hasPrefix("\($0).") }
            if let outermost = owners.min(by: { $0.count < $1.count }) {
                parentByLeaf[column] = outermost
            }
        }
        return parentByLeaf
    }

    private var metaColumns: Set<String> { Set(ElasticsearchMappingFlattener.metaColumns) }

    /// One request per change, each naming the change it writes. A change carrying a value this
    /// driver cannot send is refused whole, because writing the rest of it would let the save
    /// succeed and clear the value it left out.
    func generateRowWrites(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []

        for change in changes {
            let request: ElasticsearchWriteRequest?
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                request = try insertRequest(for: change, insertedRowData: insertedRowData)
            case .update:
                request = try updateRequest(for: change)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                request = try deleteRequest(for: change)
            }
            if let request {
                writes.append(PluginRowWrite(statement: Self.encode(request), rowIndices: [change.rowIndex]))
            }
        }

        return writes
    }

    // MARK: - INSERT

    private func insertRequest(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> ElasticsearchWriteRequest {
        var values: [String: PluginCellValue] = [:]
        if let rowData = insertedRowData[change.rowIndex] {
            for (columnIndex, column) in columns.enumerated() where columnIndex < rowData.count {
                values[column] = rowData[columnIndex]
            }
        } else {
            for cellChange in change.cellChanges {
                values[cellChange.columnName] = cellChange.newValue
            }
        }

        if let reason = unwritableInsertValue(in: change, values: values) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: reason)
        }

        var document: [String: Any] = [:]
        for column in columns where !metaColumns.contains(column) && nestedParentByLeaf[column] == nil {
            guard let value = values[column], let text = value.asText else { continue }
            document[column] = jsonValue(text, for: column)
        }

        guard let body = serialize(document) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.notJSONReason)
        }

        let explicitId = values[ElasticsearchMappingFlattener.idColumn]?.asText
        if let id = explicitId, !id.isEmpty {
            return .init(method: "PUT", path: docPath(id: id), body: body)
        }
        return .init(method: "POST", path: "/\(encodedIndex)/_doc\(Self.refreshQuery)", body: body)
    }

    /// A new row's leaf value reaches the server only inside its array, so one the user typed, or
    /// one whose array is empty, would be dropped. Metadata other than `_id` is the server's to set.
    private func unwritableInsertValue(in change: PluginRowChange, values: [String: PluginCellValue]) -> String? {
        for cellChange in change.cellChanges where !cellChange.newValue.isNull {
            let column = cellChange.columnName
            if column != ElasticsearchMappingFlattener.idColumn, metaColumns.contains(column) {
                return Self.metadataReason(column)
            }
            if let parent = nestedParentByLeaf[column] {
                return Self.nestedLeafReason(leaf: column, parent: parent)
            }
        }
        for column in columns {
            guard let parent = nestedParentByLeaf[column],
                  values[column]?.isNull == false,
                  values[parent]?.isNull ?? true
            else { continue }
            return Self.nestedLeafReason(leaf: column, parent: parent)
        }
        return nil
    }

    // MARK: - UPDATE

    private func updateRequest(for change: PluginRowChange) throws -> ElasticsearchWriteRequest? {
        guard !change.cellChanges.isEmpty else { return nil }
        guard let id = documentId(from: change) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.missingIdReason)
        }

        var doc: [String: Any] = [:]
        for cellChange in change.cellChanges {
            let column = cellChange.columnName
            if metaColumns.contains(column) {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.metadataReason(column))
            }
            if let parent = nestedParentByLeaf[column] {
                throw PluginRowWriteRefusal(
                    rowIndex: change.rowIndex, reason: Self.nestedLeafReason(leaf: column, parent: parent)
                )
            }
            if let text = cellChange.newValue.asText {
                doc[column] = jsonValue(text, for: column)
            } else {
                doc[column] = NSNull()
            }
        }

        guard let body = serialize(["doc": doc]) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.notJSONReason)
        }
        return .init(method: "POST", path: "/\(encodedIndex)/_update/\(encodePathComponent(id))\(Self.refreshQuery)", body: body)
    }

    // MARK: - DELETE

    private func deleteRequest(for change: PluginRowChange) throws -> ElasticsearchWriteRequest {
        guard let id = documentId(from: change) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.missingIdReason)
        }
        return .init(method: "DELETE", path: docPath(id: id), body: nil)
    }

    // MARK: - Refusals

    private static func nestedLeafReason(leaf: String, parent: String) -> String {
        String(format: String(localized: "'%@' is a field of a nested array. Edit the array in '%@' instead."), leaf, parent)
    }

    private static func metadataReason(_ column: String) -> String {
        String(format: String(localized: "'%@' is document metadata and cannot be edited."), column)
    }

    private static var missingIdReason: String {
        String(localized: "The document's _id is unknown, so it cannot be addressed.")
    }

    private static var notJSONReason: String {
        String(localized: "The new values cannot be written as JSON.")
    }

    // MARK: - Helpers

    private func documentId(from change: PluginRowChange) -> String? {
        guard let originalRow = change.originalRow,
              let idIndex = columns.firstIndex(of: ElasticsearchMappingFlattener.idColumn),
              idIndex < originalRow.count,
              let id = originalRow[idIndex].asText,
              !id.isEmpty
        else { return nil }
        return id
    }

    private func docPath(id: String) -> String {
        "/\(encodedIndex)/_doc/\(encodePathComponent(id))\(Self.refreshQuery)"
    }

    private var encodedIndex: String {
        encodePathComponent(index)
    }

    private static let pathComponentAllowed: CharacterSet =
        .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    private static let structuredTypes: Set<String> = ["object", "nested", "flattened", "join"]

    private func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed) ?? value
    }

    private func jsonValue(_ text: String, for column: String) -> Any {
        let typeName = columns.firstIndex(of: column).flatMap { index in
            index < columnTypeNames.count ? columnTypeNames[index] : nil
        } ?? ""

        if ElasticsearchQueryBuilder.numericTypes.contains(typeName) {
            if let intVal = Int(text) { return intVal }
            if let doubleVal = Double(text) { return doubleVal }
        }
        if typeName == "boolean" {
            let lower = text.lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
        }

        if let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            if parsed is [Any] { return parsed }
            if parsed is [String: Any], Self.structuredTypes.contains(typeName) { return parsed }
        }
        return text
    }

    private func serialize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func encode(_ request: ElasticsearchWriteRequest) -> String {
        let b64Method = Data(request.method.utf8).base64EncodedString()
        let b64Path = Data(request.path.utf8).base64EncodedString()
        let b64Body = Data((request.body ?? "").utf8).base64EncodedString()
        return "\(writeTag)\(b64Method):\(b64Path):\(b64Body)"
    }

    static func decode(_ statement: String) -> ElasticsearchWriteRequest? {
        guard statement.hasPrefix(writeTag) else { return nil }
        let parts = String(statement.dropFirst(writeTag.count)).components(separatedBy: ":")
        guard parts.count >= 3,
              let method = decodeBase64(parts[0]),
              let path = decodeBase64(parts[1])
        else { return nil }
        let body = decodeBase64(parts[2])
        return ElasticsearchWriteRequest(method: method, path: path, body: (body?.isEmpty ?? true) ? nil : body)
    }

    static func isTaggedStatement(_ statement: String) -> Bool {
        statement.hasPrefix(writeTag)
    }

    private static func decodeBase64(_ string: String) -> String? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
