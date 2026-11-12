//
//  ElasticsearchStatementGenerator.swift
//  ElasticsearchDriverPlugin
//
//  Converts tracked cell changes into tagged Elasticsearch REST mutations.
//

import Foundation
import TableProDocumentPath
import TableProNumberFormatting
import TableProPluginKit

struct ElasticsearchWriteRequest: Equatable {
    let method: String
    let path: String
    let body: String?
    // The fields a partial update sets, each as its mapping keys. The stored document decides how
    // each one is spelled, so the request is aligned to it when it runs.
    let leafPaths: [[String]]
    // Leaves of `leafPaths` sent as text that reads as a JSON array. The grid shows the string `["a"]` and the array
    // `["a"]` alike, so the stored document decides which one the edit is.
    let arrayCandidates: [[String]]

    init(method: String, path: String, body: String?, leafPaths: [[String]] = [], arrayCandidates: [[String]] = []) {
        self.method = method
        self.path = path
        self.body = body
        self.leafPaths = leafPaths
        self.arrayCandidates = arrayCandidates
    }
}

// Where a hit lives: its concrete index (a search can go through an alias or a wildcard) and, for a document indexed
// with custom routing, the routing that finds its shard again. With custom routing an `_id` is unique only per shard.
struct ElasticsearchDocumentLocator: Equatable {
    let index: String
    let id: String
    let routing: String?

    private static let indexKey = "_index"
    private static let idKey = "_id"
    private static let routingKey = "_routing"

    init(index: String, id: String, routing: String?) {
        self.index = index
        self.id = id
        self.routing = routing
    }

    init?(hit: [String: Any]) {
        guard let index = hit[Self.indexKey] as? String, let id = hit[Self.idKey] as? String else { return nil }
        self.init(index: index, id: id, routing: hit[Self.routingKey] as? String)
    }

    init?(locator: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(locator.utf8)) as? [String: Any] else {
            return nil
        }
        self.init(hit: object)
    }

    // Sorted keys, so the same hit always gives the same text.
    var locator: String? {
        var object: [String: Any] = [Self.indexKey: index, Self.idKey: id]
        if let routing { object[Self.routingKey] = routing }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct ElasticsearchStatementGenerator {
    static let writeTag = "ELASTICSEARCH_WRITE:"
    private static let refreshQuery = "?refresh=true"
    // Plain `PUT _doc/<id>` replaces a document that already has the id.
    private static let createOnlyQuery = "&op_type=create"
    private static let updateEndpoint = "_update"
    private static let documentEndpoint = "_doc"
    private static let routingParameter = "routing="

    let index: String
    let columns: [String]
    let columnTypeNames: [String]
    // By row index, the `ElasticsearchDocumentLocator` text each hit was read with.
    let rowLocators: [Int: String]
    // String fields some hit held a string reading as a JSON array in.
    let arrayTextColumns: Set<String>

    /// A `nested` column carries the whole array of objects, and its dotted leaves are views of
    /// those same bytes. Writing both makes Elasticsearch expand the dotted key into the object the
    /// array already fills, which it rejects as a mapping conflict, so the array is written once
    /// through its parent and a value typed into a leaf is refused rather than sent. Each leaf maps
    /// to the outermost array it belongs to, which is the column that writes it.
    private let nestedParentByLeaf: [String: String]
    private let columnPathKeys: [String: [String]]

    init(
        index: String,
        columns: [String],
        columnTypeNames: [String],
        columnPathKeys: [String: [String]] = [:],
        rowLocators: [Int: String] = [:],
        arrayTextColumns: Set<String> = []
    ) {
        self.index = index
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.columnPathKeys = columnPathKeys
        self.rowLocators = rowLocators
        self.arrayTextColumns = arrayTextColumns
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

        if let column = shortenedColumn(in: values) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.shortenedValueReason(column))
        }
        if let reason = unwritableInsertValue(in: change, values: values) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: reason)
        }

        var document: [String: Any] = [:]
        for column in columns where !metaColumns.contains(column) && nestedParentByLeaf[column] == nil {
            guard let value = values[column], let text = value.asText else { continue }
            let json = jsonValue(text, for: column)
            guard DocumentPathPlacement.set(json, atKeys: pathKeys(for: column), in: &document) else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.notJSONReason)
            }
        }

        guard let body = Self.serialize(document) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.notJSONReason)
        }

        let explicitId = values[ElasticsearchMappingFlattener.idColumn]?.asText
        if let id = explicitId, !id.isEmpty {
            return .init(method: "PUT", path: docPath(id: id) + Self.createOnlyQuery, body: body)
        }
        return .init(method: "POST", path: "/\(encodedIndex)/_doc\(Self.refreshQuery)", body: body)
    }

    private func shortenedColumn(in values: [String: PluginCellValue]) -> String? {
        columns.first { values[$0].map(Self.isShortened) ?? false }
    }

    private static func isShortened(_ value: PluginCellValue) -> Bool {
        value.asText.map(JSONTruncation.isIncompleteStructure) ?? false
    }

    /// A new row's leaf value reaches the server only inside its array, so one the user typed, one
    /// whose array is empty, or one that says something other than its array would be dropped.
    /// Metadata other than `_id` is the server's to set.
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
            guard let parent = nestedParentByLeaf[column], let leaf = values[column], !leaf.isNull else { continue }
            guard let array = values[parent]?.asText,
                  Self.sameCell(leaf, projectedLeaf(column, of: parent, arrayText: array)) else {
                return Self.nestedLeafReason(leaf: column, parent: parent)
            }
        }
        return nil
    }

    /// What the grid shows for `leaf` once `arrayText` is saved into `parent`, read by the same
    /// flattener that reads the document back.
    private func projectedLeaf(_ leaf: String, of parent: String, arrayText: String) -> PluginCellValue {
        let placed = parent.split(separator: ".").reversed().reduce(jsonValue(arrayText, for: parent)) { inner, key in
            [String(key): inner]
        }
        guard let source = placed as? [String: Any] else { return .null }
        let flat = ElasticsearchMappingFlattener.flattenSource(source, nestedParents: [parent], length: .display)
        return flat[leaf] ?? .null
    }

    /// Two cells that hold the same JSON value compare equal however it is spaced.
    private static func sameCell(_ lhs: PluginCellValue, _ rhs: PluginCellValue) -> Bool {
        guard let left = lhs.asText, let right = rhs.asText else { return lhs.isNull && rhs.isNull }
        guard let leftValue = parsedJSON(left), let rightValue = parsedJSON(right) else { return left == right }
        return (leftValue as AnyObject).isEqual(rightValue)
    }

    private static func parsedJSON(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    // MARK: - UPDATE

    private func updateRequest(for change: PluginRowChange) throws -> ElasticsearchWriteRequest? {
        guard !change.cellChanges.isEmpty else { return nil }
        let target = try document(for: change)

        var doc: [String: Any] = [:]
        var leafPaths: [[String]] = []
        var arrayCandidates: [[String]] = []
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
            if !cellChange.newValue.isNull,
               Self.isShortened(cellChange.newValue) || Self.isShortened(cellChange.oldValue) {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.shortenedValueReason(column))
            }
            let keys = pathKeys(for: column)
            let text = cellChange.newValue.asText
            let value: Any
            if let text, holdsTextOrArray(column), Self.parsedArray(text) != nil {
                value = text
                arrayCandidates.append(keys)
            } else {
                value = text.map { jsonValue($0, for: column) } ?? NSNull()
            }
            guard DocumentPathPlacement.set(value, atKeys: keys, in: &doc) else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.notJSONReason)
            }
            leafPaths.append(keys)
        }

        guard let body = Self.serialize(["doc": doc]) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.notJSONReason)
        }
        return .init(
            method: "POST",
            path: documentPath(Self.updateEndpoint, for: target),
            body: body,
            leafPaths: leafPaths,
            arrayCandidates: arrayCandidates
        )
    }

    // MARK: - Stored Document Alignment

    static func isCreateOnly(_ request: ElasticsearchWriteRequest) -> Bool {
        request.path.hasSuffix(createOnlyQuery)
    }

    // A routed document is found only on its routing's shard, so the read carries the update's routing.
    static func storedDocumentPath(for request: ElasticsearchWriteRequest) -> String? {
        guard !request.leafPaths.isEmpty else { return nil }
        let pathAndQuery = request.path.split(separator: "?", maxSplits: 1)
        let parts = (pathAndQuery.first ?? "").split(separator: "/")
        guard parts.count == 3, parts[1] == updateEndpoint else { return nil }
        let routing = pathAndQuery.dropFirst().first?
            .split(separator: "&")
            .first(where: { $0.hasPrefix(routingParameter) })
        return "/\(parts[0])/\(documentEndpoint)/\(parts[2])" + (routing.map { "?\($0)" } ?? "")
    }

    static func aligned(
        _ request: ElasticsearchWriteRequest,
        toStored stored: [String: Any],
        seqNo: Int?,
        primaryTerm: Int?
    ) throws -> ElasticsearchWriteRequest {
        guard let body = request.body,
              let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let doc = parsed["doc"] as? [String: Any]
        else { return request }

        var placed: [String: Any] = [:]
        for keys in request.leafPaths {
            guard var value = DocumentPathPlacement.value(in: doc, atKeys: keys) else { return request }
            if request.arrayCandidates.contains(keys), let text = value as? String, let array = parsedArray(text),
               storedHoldsArray(atKeys: keys, in: stored) {
                value = array
            }
            try DocumentPathPlacement.place(value, atKeys: keys, in: &placed, following: stored)
        }
        guard let alignedBody = serialize(["doc": placed]) else { return request }

        var path = request.path
        if let seqNo, let primaryTerm {
            path += "&if_seq_no=\(seqNo)&if_primary_term=\(primaryTerm)"
        }
        return ElasticsearchWriteRequest(method: request.method, path: path, body: alignedBody)
    }

    // Every spelling the stored document has for the field holds an array.
    private static func storedHoldsArray(atKeys keys: [String], in stored: [String: Any]) -> Bool {
        let atoms = keys.flatMap { $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init) }
        let found = storedValues(of: atoms[...], in: stored)
        return !found.isEmpty && found.allSatisfy { $0 is [Any] }
    }

    // The same walk as `DocumentPathPlacement.place`: a level can spell the next part of the path as one dotted key.
    private static func storedValues(of atoms: ArraySlice<String>, in level: [String: Any]) -> [Any] {
        var found: [Any] = []
        for end in atoms.indices.map({ $0 + 1 }) {
            let key = atoms[atoms.startIndex..<end].joined(separator: ".")
            guard let value = level[key] else { continue }
            if end == atoms.endIndex {
                found.append(value)
            } else if let object = value as? [String: Any] {
                found += storedValues(of: atoms[end...], in: object)
            }
        }
        return found
    }

    // MARK: - DELETE

    private func deleteRequest(for change: PluginRowChange) throws -> ElasticsearchWriteRequest {
        let target = try document(for: change)
        return .init(method: "DELETE", path: documentPath(Self.documentEndpoint, for: target), body: nil)
    }

    // MARK: - Refusals

    private static func nestedLeafReason(leaf: String, parent: String) -> String {
        String(format: String(localized: "'%@' is a field of a nested array. Edit the array in '%@' instead."), leaf, parent)
    }

    private static func metadataReason(_ column: String) -> String {
        String(format: String(localized: "'%@' is document metadata and cannot be edited."), column)
    }

    private static func shortenedValueReason(_ column: String) -> String {
        String(
            format: String(
                localized: "The value in %@ is shortened for display, so saving it would store only the part shown. Change this field with a query."
            ),
            column
        )
    }

    private static var missingIdReason: String {
        String(localized: "The document's _id is unknown, so it cannot be addressed.")
    }

    private static var notJSONReason: String {
        String(localized: "The new values cannot be written as JSON.")
    }

    // MARK: - Helpers

    // A row read from a table tab carries its hit's locator. Without one, the tab's index and the `_id` cell.
    private func document(for change: PluginRowChange) throws -> ElasticsearchDocumentLocator {
        if let locator = rowLocators[change.rowIndex] {
            guard let document = ElasticsearchDocumentLocator(locator: locator) else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.missingIdReason)
            }
            return document
        }
        guard let id = documentId(from: change) else {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.missingIdReason)
        }
        return ElasticsearchDocumentLocator(index: index, id: id, routing: nil)
    }

    private func documentId(from change: PluginRowChange) -> String? {
        guard let originalRow = change.originalRow,
              let idIndex = columns.firstIndex(of: ElasticsearchMappingFlattener.idColumn),
              idIndex < originalRow.count,
              let id = originalRow[idIndex].asText,
              !id.isEmpty
        else { return nil }
        return id
    }

    private func pathKeys(for column: String) -> [String] {
        columnPathKeys[column] ?? column.split(separator: ".").map(String.init)
    }

    private func docPath(id: String) -> String {
        documentPath(Self.documentEndpoint, for: ElasticsearchDocumentLocator(index: index, id: id, routing: nil))
    }

    private func documentPath(_ endpoint: String, for document: ElasticsearchDocumentLocator) -> String {
        let path = "/\(encodePathComponent(document.index))/\(endpoint)/\(encodePathComponent(document.id))\(Self.refreshQuery)"
        guard let routing = document.routing else { return path }
        return path + "&" + Self.routingParameter + Self.encodeQueryValue(routing)
    }

    private var encodedIndex: String {
        encodePathComponent(index)
    }

    private static let pathComponentAllowed: CharacterSet =
        .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    // RFC 3986 unreserved: `&`, `=`, `+`, `#` and `%` in a routing value would end or change the parameter.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    private static let structuredTypes: Set<String> = ["object", "nested", "flattened", "join"]
    static let stringTypes: Set<String> = [
        "text", "keyword", "wildcard", "constant_keyword", "match_only_text", "search_as_you_type", "annotated_text"
    ]

    private func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed) ?? value
    }

    private static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }

    private func mappedType(of column: String) -> String {
        columns.firstIndex(of: column).flatMap { index in
            index < columnTypeNames.count ? columnTypeNames[index] : nil
        } ?? ""
    }

    // A string field, or one whose type is unknown, can hold a string that reads as a JSON array.
    private func holdsTextOrArray(_ column: String) -> Bool {
        let typeName = mappedType(of: column)
        return typeName.isEmpty || Self.stringTypes.contains(typeName)
    }

    // JSON allows white space before the bracket; anything else is not an array and is never copied and parsed.
    static func parsedArray(_ text: String) -> [Any]? {
        guard text.unicodeScalars.first(where: { !" \t\n\r".unicodeScalars.contains($0) }) == "[" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any]
    }

    private func jsonValue(_ text: String, for column: String) -> Any {
        let typeName = mappedType(of: column)

        if Self.stringTypes.contains(typeName) {
            // A new row has no stored value to compare, so an array is read as one unless the field held such text.
            if !arrayTextColumns.contains(column), let array = Self.parsedArray(text) { return array }
            return text
        }
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

    private static func serialize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func encode(_ request: ElasticsearchWriteRequest) -> String {
        let b64Method = Data(request.method.utf8).base64EncodedString()
        let b64Path = Data(request.path.utf8).base64EncodedString()
        let b64Body = Data((request.body ?? "").utf8).base64EncodedString()
        let statement = "\(writeTag)\(b64Method):\(b64Path):\(b64Body)"
        guard !request.leafPaths.isEmpty,
              let leafData = try? JSONSerialization.data(withJSONObject: request.leafPaths)
        else { return statement }
        let withLeaves = "\(statement):\(leafData.base64EncodedString())"
        guard !request.arrayCandidates.isEmpty,
              let candidateData = try? JSONSerialization.data(withJSONObject: request.arrayCandidates)
        else { return withLeaves }
        return "\(withLeaves):\(candidateData.base64EncodedString())"
    }

    static func decode(_ statement: String) -> ElasticsearchWriteRequest? {
        guard statement.hasPrefix(writeTag) else { return nil }
        let parts = String(statement.dropFirst(writeTag.count)).components(separatedBy: ":")
        guard parts.count >= 3,
              let method = decodeBase64(parts[0]),
              let path = decodeBase64(parts[1])
        else { return nil }
        let body = decodeBase64(parts[2])
        return ElasticsearchWriteRequest(
            method: method,
            path: path,
            body: (body?.isEmpty ?? true) ? nil : body,
            leafPaths: parts.count > 3 ? decodePaths(parts[3]) : [],
            arrayCandidates: parts.count > 4 ? decodePaths(parts[4]) : []
        )
    }

    private static func decodePaths(_ part: String) -> [[String]] {
        Data(base64Encoded: part).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String]] } ?? []
    }

    static func isTaggedStatement(_ statement: String) -> Bool {
        statement.hasPrefix(writeTag)
    }

    private static func decodeBase64(_ string: String) -> String? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
