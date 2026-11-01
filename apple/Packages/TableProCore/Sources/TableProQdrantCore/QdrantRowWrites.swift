import Foundation

public struct QdrantCell: Sendable, Equatable {
    public let column: String
    public let text: String?

    public init(column: String, text: String?) {
        self.column = column
        self.text = text
    }
}

public struct QdrantRowChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case insert
        case update
        case delete
    }

    public let kind: Kind
    public let rowIndex: Int
    public let id: String?
    // An insert's every column, or an update's changed cells.
    public let cells: [QdrantCell]

    public init(kind: Kind, rowIndex: Int, id: String?, cells: [QdrantCell] = []) {
        self.kind = kind
        self.rowIndex = rowIndex
        self.id = id
        self.cells = cells
    }
}

public struct QdrantRowWrite: Sendable, Equatable {
    public let request: QdrantConsoleRequest
    public let rowIndex: Int
    // A read that must find no point before the write runs: an insert that leaves a taken id alone
    // still answers success, so without it the save would report a row it never added.
    public let mustFindNothing: QdrantConsoleRequest?
    // Run right after the write: a row back means the point under the id is not the one written, which
    // happens when another client takes the id between the lookup and the write.
    public let landedCheck: String?
}

public enum QdrantInsertCheck {
    public static let tag = "QDRANT_INSERT_CHECK:"

    public static func encode(collection: String, id: Any, payload: [String: Any]) -> String? {
        guard let data = try? QdrantJSON.data(["collection": collection, "id": id, "payload": payload]) else { return nil }
        return tag + data.base64EncodedString()
    }

    public static func decode(_ text: String) -> (collection: String, id: Any, payload: [String: Any])? {
        guard text.hasPrefix(tag),
              let data = Data(base64Encoded: String(text.dropFirst(tag.count))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collection = object["collection"] as? String, let id = object["id"],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return (collection, id, payload)
    }

    public static func landed(_ point: QdrantPoint?, payload: [String: Any]) -> Bool {
        guard let point else { return false }
        return (try? QdrantJSON.text(point.payload)) == (try? QdrantJSON.text(payload))
    }
}

public enum QdrantServerVersion {
    public static func hasQueryAPI(_ version: String?) -> Bool {
        isAtLeast(version, major: 1, minor: 10)
    }

    // Measured: 1.15.5 and later honor `update_filter`; 1.13.6 and 1.14.1 ignore it and overwrite the
    // point. `update_mode: insert_only` is ignored the same way on 1.16.3.
    public static func insertsWithoutOverwrite(_ version: String?) -> Bool {
        isAtLeast(version, major: 1, minor: 15)
    }

    static func isAtLeast(_ version: String?, major: Int, minor: Int) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").prefix(2).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        guard parts.count == 2 else { return false }
        return parts[0] > major || (parts[0] == major && parts[1] >= minor)
    }
}

public struct QdrantRowRefusal: Error, LocalizedError, Equatable, Sendable {
    public let rowIndex: Int
    public let reason: String

    public var errorDescription: String? { reason }
}

public enum QdrantRowWriter {
    public static func writes(
        collection: String,
        changes: [QdrantRowChange],
        serverVersion: String?,
        typeName: (String) -> String?,
        newID: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> [QdrantRowWrite] {
        let points = "/collections/\(QdrantPathEncoding.segment(collection))/points"
        let insertsSafely = QdrantServerVersion.insertsWithoutOverwrite(serverVersion)
        var writes: [QdrantRowWrite] = []
        for change in changes {
            do {
                if change.kind == .insert, !insertsSafely {
                    throw Reason(text: String(
                        format: String(localized: "Qdrant %@ overwrites a point that already has the id. Insert it from the REST editor, or upgrade Qdrant to 1.15 or later."),
                        serverVersion ?? "?"
                    ))
                }
                writes += try self.writes(for: change, collection: collection, points: points, typeName: typeName, newID: newID)
            } catch let error as QdrantValueError {
                throw QdrantRowRefusal(rowIndex: change.rowIndex, reason: error.errorDescription ?? "")
            } catch let reason as Reason {
                throw QdrantRowRefusal(rowIndex: change.rowIndex, reason: reason.text)
            }
        }
        return writes
    }

    private struct Reason: Error {
        let text: String
    }

    private static func writes(
        for change: QdrantRowChange,
        collection: String,
        points: String,
        typeName: (String) -> String?,
        newID: () -> String
    ) throws -> [QdrantRowWrite] {
        switch change.kind {
        case .delete:
            let id = try pointID(change.id)
            return [try write("POST", "\(points)/delete?wait=true", ["points": [id]], change)]
        case .insert:
            let cells = change.cells.filter { $0.text != nil && $0.text != defaultMarker }
            let idText = cells.first { $0.column == QdrantSchema.idColumn }?.text.flatMap { $0.isEmpty ? nil : $0 }
            let id = try pointID(idText ?? newID())
            let values = try typedValues(cells, typeName: typeName)
            let point: [String: Any] = ["id": id, "vector": values.vectors, "payload": values.payload]
            let lookup = try request("POST", points, ["ids": [id], "with_payload": false, "with_vector": false])
            return [QdrantRowWrite(
                request: try request("PUT", "\(points)?wait=true", ["points": [point], "update_filter": Self.matchesNoPoint]),
                rowIndex: change.rowIndex,
                mustFindNothing: lookup,
                landedCheck: QdrantInsertCheck.encode(collection: collection, id: id, payload: values.payload)
            )]
        case .update:
            let id = try pointID(change.id)
            guard !change.cells.contains(where: { $0.column == QdrantSchema.idColumn }) else {
                throw Reason(text: String(localized: "A point's id cannot change. Insert a new row with the new id instead."))
            }
            let values = try typedValues(change.cells, typeName: typeName)
            var writes: [QdrantRowWrite] = []
            if !values.payload.isEmpty {
                writes.append(try write("POST", "\(points)/payload?wait=true", ["payload": values.payload, "points": [id]], change))
            }
            if !values.vectors.isEmpty {
                let body: [String: Any] = ["points": [["id": id, "vector": values.vectors]]]
                writes.append(try write("PUT", "\(points)/vectors?wait=true", body, change))
            }
            if !values.clearedVectors.isEmpty {
                let body: [String: Any] = ["points": [id], "vector": values.clearedVectors]
                writes.append(try write("POST", "\(points)/vectors/delete?wait=true", body, change))
            }
            return writes
        }
    }

    // The host's marker for a cell the server fills; a duplicated row carries it in its key.
    static let defaultMarker = "__DEFAULT__"

    // An upsert updates only existing points this filter matches, and it matches none.
    private static var matchesNoPoint: [String: Any] { ["must": [["has_id": [Any]()]]] }

    private struct TypedValues {
        var payload: [String: Any] = [:]
        var vectors: [String: Any] = [:]
        var clearedVectors: [String] = []
    }

    private static func typedValues(_ cells: [QdrantCell], typeName: (String) -> String?) throws -> TypedValues {
        var values = TypedValues()
        for cell in cells where cell.column != QdrantSchema.idColumn {
            guard let type = typeName(cell.column) else { throw unknownType(cell.column) }
            if let name = QdrantSchema.vectorName(ofColumn: cell.column) {
                guard let kind = QdrantVectorSpec.kind(ofTypeName: type) else { throw unknownType(cell.column) }
                if let text = cell.text {
                    values.vectors[name] = try QdrantValue.vector(text, kind: kind, column: cell.column)
                } else {
                    values.clearedVectors.append(name)
                }
                continue
            }
            guard let fieldType = QdrantFieldType(rawValue: type.lowercased()) else { throw unknownType(cell.column) }
            let key = QdrantSchema.payloadKey(forColumn: cell.column)
            values.payload[key] = try cell.text.map { try QdrantValue.payload($0, type: fieldType, column: cell.column) } ?? NSNull()
        }
        return values
    }

    private static func unknownType(_ column: String) -> Reason {
        Reason(text: String(format: String(localized: "TablePro does not know what %@ holds. Reload the collection, then save again."), column))
    }

    private static func pointID(_ text: String?) throws -> Any {
        guard let text, !text.isEmpty else {
            throw Reason(text: String(localized: "This row has no point id, so Qdrant cannot tell which point to change."))
        }
        guard let id = QdrantPointID.json(from: text) else {
            throw Reason(text: String(QdrantFilterError.notAPointID(value: text).errorDescription ?? ""))
        }
        return id
    }

    private static func write(_ method: String, _ path: String, _ body: [String: Any], _ change: QdrantRowChange) throws -> QdrantRowWrite {
        QdrantRowWrite(request: try request(method, path, body), rowIndex: change.rowIndex, mustFindNothing: nil, landedCheck: nil)
    }

    private static func request(_ method: String, _ path: String, _ body: [String: Any]) throws -> QdrantConsoleRequest {
        QdrantConsoleRequest(method: method, path: path, body: try QdrantJSON.text(body))
    }
}
