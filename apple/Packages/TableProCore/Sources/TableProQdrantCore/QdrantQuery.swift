import Foundation

public struct QdrantSortSpec: Sendable, Equatable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public struct QdrantBrowseRequest: Sendable, Equatable {
    public let collection: String
    public let offset: Int
    public let limit: Int
    public let sort: QdrantSortSpec?
    public let filters: [QdrantFilterSpec]
    public let logicMode: String

    public init(
        collection: String,
        offset: Int,
        limit: Int,
        sort: QdrantSortSpec?,
        filters: [QdrantFilterSpec],
        logicMode: String
    ) {
        self.collection = collection
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.sort = sort
        self.filters = filters
        self.logicMode = logicMode
    }
}

/// A grid page travels from `buildFilteredQuery` to `execute` as tagged text, because the page is
/// built before the driver knows the collection's field types the filter JSON depends on.
public enum QdrantBrowseQuery {
    public static let tag = "QDRANT_BROWSE:"

    public static func encode(_ request: QdrantBrowseRequest) -> String {
        var payload: [String: Any] = [
            "collection": request.collection,
            "offset": request.offset,
            "limit": request.limit,
            "logicMode": request.logicMode,
            "filters": request.filters.map { filter -> [String: Any] in
                var encoded: [String: Any] = ["column": filter.column, "op": filter.op, "value": filter.value]
                if let secondValue = filter.secondValue {
                    encoded["secondValue"] = secondValue
                }
                return encoded
            }
        ]
        if let sort = request.sort {
            payload["sort"] = ["column": sort.column, "ascending": sort.ascending]
        }
        let body = (try? QdrantJSON.data(payload)) ?? Data()
        return tag + body.base64EncodedString()
    }

    public static func parse(_ query: String) -> QdrantBrowseRequest? {
        guard query.hasPrefix(tag),
              let data = Data(base64Encoded: String(query.dropFirst(tag.count))),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collection = json["collection"] as? String
        else { return nil }
        let sort = (json["sort"] as? [String: Any]).flatMap { item -> QdrantSortSpec? in
            guard let column = item["column"] as? String else { return nil }
            return QdrantSortSpec(column: column, ascending: item["ascending"] as? Bool ?? true)
        }
        let filters = (json["filters"] as? [[String: Any]] ?? []).compactMap { item -> QdrantFilterSpec? in
            guard let column = item["column"] as? String, let op = item["op"] as? String else { return nil }
            return QdrantFilterSpec(
                column: column,
                op: op,
                value: item["value"] as? String ?? "",
                secondValue: item["secondValue"] as? String
            )
        }
        return QdrantBrowseRequest(
            collection: collection,
            offset: json["offset"] as? Int ?? 0,
            limit: json["limit"] as? Int ?? 100,
            sort: sort,
            filters: filters,
            logicMode: json["logicMode"] as? String ?? "AND"
        )
    }

    public static func isTagged(_ query: String) -> Bool {
        query.hasPrefix(tag)
    }

    /// The body of one page. `order_by` is only on the query endpoint, which takes a numeric offset;
    /// an unsorted page goes through `scroll`, which pages by point id instead.
    public static func queryBody(
        for request: QdrantBrowseRequest,
        filter: [String: Any]?,
        sort: QdrantSortSpec
    ) -> [String: Any] {
        var body: [String: Any] = [
            "query": ["order_by": [
                "key": QdrantSchema.payloadKey(forColumn: sort.column),
                "direction": sort.ascending ? "asc" : "desc"
            ]],
            "limit": request.limit,
            "offset": request.offset,
            "with_payload": true,
            "with_vector": true
        ]
        if let filter {
            body["filter"] = filter
        }
        return body
    }

    public static func scrollBody(
        filter: [String: Any]?,
        limit: Int,
        cursor: Any?,
        withData: Bool,
        withVector: Bool? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "limit": limit,
            "with_payload": withData,
            "with_vector": withVector ?? withData
        ]
        if let filter {
            body["filter"] = filter
        }
        if let cursor {
            body["offset"] = cursor
        }
        return body
    }
}

public struct QdrantWriteRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let body: String?

    public init(method: String, path: String, body: String?) {
        self.method = method
        self.path = path
        self.body = body
    }
}

/// A grid save is shown in the review sheet and runs as the request line the console would send,
/// so what the user approves, what the read-only gate classifies and what runs are one string.
public enum QdrantWriteCodec {
    public static func encode(_ request: QdrantWriteRequest) -> String {
        guard let body = request.body else { return "\(request.method) \(request.path)" }
        return "\(request.method) \(request.path)\n\(body)"
    }
}

public struct QdrantCellChange: Sendable, Equatable {
    public let column: String
    public let newText: String?

    public init(column: String, newText: String?) {
        self.column = column
        self.newText = newText
    }
}

public struct QdrantTrackedChange: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case insert
        case update
        case delete
    }

    public let kind: Kind
    public let id: String?
    public let values: [String: String?]
    public let cellChanges: [QdrantCellChange]

    public init(kind: Kind, id: String?, values: [String: String?] = [:], cellChanges: [QdrantCellChange] = []) {
        self.kind = kind
        self.id = id
        self.values = values
        self.cellChanges = cellChanges
    }
}

public enum QdrantSkipReason: String, Sendable, Equatable {
    case missingID
    case invalidID
    case noEditableColumns
    case payloadNotEncodable
}

public struct QdrantSkippedChange: Sendable, Equatable {
    public let kind: QdrantTrackedChange.Kind
    public let reason: QdrantSkipReason
}

public struct QdrantWriteBatch: Sendable, Equatable {
    public let requests: [QdrantWriteRequest]
    public let skipped: [QdrantSkippedChange]
}

public enum QdrantStatementGenerator {
    /// `uuid` supplies the id of an inserted row the user left blank.
    public static func generate(
        collection: QdrantCollection,
        changes: [QdrantTrackedChange],
        uuid: () -> String = { UUID().uuidString.lowercased() }
    ) -> QdrantWriteBatch {
        let base = "/collections/\(QdrantPathEncoding.segment(collection.name))/points"
        var requests: [QdrantWriteRequest] = []
        var skipped: [QdrantSkippedChange] = []

        for change in changes {
            switch outcome(for: change, collection: collection, base: base, uuid: uuid) {
            case .success(let request):
                requests.append(request)
            case .failure(let reason):
                skipped.append(QdrantSkippedChange(kind: change.kind, reason: reason))
            }
        }
        return QdrantWriteBatch(requests: requests, skipped: skipped)
    }

    private enum Outcome {
        case success(QdrantWriteRequest)
        case failure(QdrantSkipReason)
    }

    private static func outcome(
        for change: QdrantTrackedChange,
        collection: QdrantCollection,
        base: String,
        uuid: () -> String
    ) -> Outcome {
        let immutable = Set(QdrantSchema.immutableColumns(for: collection))
        switch change.kind {
        case .insert:
            let idText = change.id.flatMap { $0.isEmpty ? nil : $0 } ?? uuid()
            guard let id = QdrantPointID.json(from: idText) else { return .failure(.invalidID) }
            let payload = payloadObject(
                change.values.filter { !immutable.contains($0.key) },
                collection: collection
            )
            // `insert_only` keeps an id that already exists from being overwritten, vector and all.
            let body: [String: Any] = [
                "points": [["id": id, "vector": [String: Any](), "payload": payload]],
                "update_mode": "insert_only"
            ]
            return request("PUT", "\(base)?wait=true", body)
        case .update:
            guard let idText = change.id, !idText.isEmpty else { return .failure(.missingID) }
            guard let id = QdrantPointID.json(from: idText) else { return .failure(.invalidID) }
            var patch: [String: String?] = [:]
            for cell in change.cellChanges where !immutable.contains(cell.column) {
                patch[cell.column] = cell.newText
            }
            guard !patch.isEmpty else { return .failure(.noEditableColumns) }
            let body: [String: Any] = ["payload": payloadObject(patch, collection: collection), "points": [id]]
            return request("POST", "\(base)/payload?wait=true", body)
        case .delete:
            guard let idText = change.id, !idText.isEmpty else { return .failure(.missingID) }
            guard let id = QdrantPointID.json(from: idText) else { return .failure(.invalidID) }
            return request("POST", "\(base)/delete?wait=true", ["points": [id]])
        }
    }

    private static func request(_ method: String, _ path: String, _ body: [String: Any]) -> Outcome {
        guard let text = try? QdrantJSON.text(body) else { return .failure(.payloadNotEncodable) }
        return .success(QdrantWriteRequest(method: method, path: path, body: text))
    }

    private static func payloadObject(_ values: [String: String?], collection: QdrantCollection) -> [String: Any] {
        var payload: [String: Any] = [:]
        for (column, text) in values {
            guard let text else {
                payload[QdrantSchema.payloadKey(forColumn: column)] = NSNull()
                continue
            }
            payload[QdrantSchema.payloadKey(forColumn: column)] = QdrantJSON.parsedValue(
                text,
                fieldType: collection.fieldType(of: column) ?? .string
            )
        }
        return payload
    }
}
