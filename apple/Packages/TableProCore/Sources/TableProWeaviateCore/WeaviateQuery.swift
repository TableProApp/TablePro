import Foundation

public struct WeaviateFilterSpec: Codable, Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String

    /// The upper bound of `BETWEEN`, carried apart from `value` so a value holding a comma cannot
    /// be mistaken for the separator between the two bounds.
    public let secondValue: String?

    public init(column: String, op: String, value: String, secondValue: String? = nil) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }
}

public struct WeaviateSortSpec: Codable, Sendable, Equatable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public struct WeaviateParsedSearch: Sendable, Equatable {
    public let collection: String
    public let offset: Int
    public let limit: Int
    public let sorts: [WeaviateSortSpec]
    public let filters: [WeaviateFilterSpec]
    public let logicMode: String
    public let propertyNames: [String]

    public init(
        collection: String,
        offset: Int,
        limit: Int,
        sorts: [WeaviateSortSpec],
        filters: [WeaviateFilterSpec],
        logicMode: String,
        propertyNames: [String]
    ) {
        self.collection = collection
        self.offset = offset
        self.limit = limit
        self.sorts = sorts
        self.filters = filters
        self.logicMode = logicMode
        self.propertyNames = propertyNames
    }

    /// `GET /v1/objects` sorts, but only on a property: the grid's `vector` column is not one, and
    /// Weaviate answers `no such prop with name 'vector'`. Everything else goes through GraphQL,
    /// whose `sort` argument takes the object id as well.
    public var sortableSorts: [WeaviateSortSpec] {
        sorts.filter { $0.column != WeaviateSchema.vectorColumn }
    }

    public var usesGraphQL: Bool {
        !filters.isEmpty || !sortableSorts.isEmpty
    }
}

public enum WeaviateBrowseQuery {
    public static let searchTag = "WEAVIATE_SEARCH:"

    public static func encode(
        collection: String,
        offset: Int,
        limit: Int,
        sorts: [WeaviateSortSpec],
        filters: [WeaviateFilterSpec],
        logicMode: String,
        propertyNames: [String]
    ) -> String {
        let payload: [String: Any] = [
            "collection": collection,
            "offset": offset,
            "limit": limit,
            "logicMode": logicMode,
            "sorts": sorts.map { ["column": $0.column, "ascending": $0.ascending] },
            "filters": filters.map { filter -> [String: Any] in
                var encoded: [String: Any] = ["column": filter.column, "op": filter.op, "value": filter.value]
                if let secondValue = filter.secondValue {
                    encoded["secondValue"] = secondValue
                }
                return encoded
            },
            "properties": propertyNames
        ]
        let body = (try? WeaviateJSON.data(payload)) ?? Data()
        return searchTag + body.base64EncodedString()
    }

    public static func parse(_ query: String) -> WeaviateParsedSearch? {
        guard query.hasPrefix(searchTag) else { return nil }
        let encoded = String(query.dropFirst(searchTag.count))
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collection = json["collection"] as? String
        else { return nil }
        let sortsJSON = json["sorts"] as? [[String: Any]] ?? []
        let filtersJSON = json["filters"] as? [[String: Any]] ?? []
        let properties = json["properties"] as? [String] ?? []
        return WeaviateParsedSearch(
            collection: collection,
            offset: json["offset"] as? Int ?? 0,
            limit: json["limit"] as? Int ?? 25,
            sorts: sortsJSON.compactMap { item in
                guard let column = item["column"] as? String else { return nil }
                return WeaviateSortSpec(column: column, ascending: item["ascending"] as? Bool ?? true)
            },
            filters: filtersJSON.compactMap { item in
                guard let column = item["column"] as? String, let op = item["op"] as? String else {
                    return nil
                }
                return WeaviateFilterSpec(
                    column: column,
                    op: op,
                    value: item["value"] as? String ?? "",
                    secondValue: item["secondValue"] as? String
                )
            },
            logicMode: json["logicMode"] as? String ?? "AND",
            propertyNames: properties
        )
    }

    public static func isTagged(_ query: String) -> Bool {
        query.hasPrefix(searchTag)
    }
}

public struct WeaviateWriteRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: String?

    public init(method: String, path: String, query: [String: String] = [:], body: String?) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }
}

public enum WeaviateWriteCodec {
    public static let writeTag = "WEAVIATE_WRITE:"

    public static func encode(_ request: WeaviateWriteRequest) -> String {
        let payload: [String: Any] = [
            "method": request.method,
            "path": request.path,
            "query": request.query,
            "body": request.body ?? ""
        ]
        let data = (try? WeaviateJSON.data(payload)) ?? Data()
        return writeTag + data.base64EncodedString()
    }

    public static func decode(_ statement: String) -> WeaviateWriteRequest? {
        guard statement.hasPrefix(writeTag) else { return nil }
        let encoded = String(statement.dropFirst(writeTag.count))
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              let path = json["path"] as? String
        else { return nil }
        let query = json["query"] as? [String: String] ?? [:]
        let body = json["body"] as? String
        return WeaviateWriteRequest(
            method: method,
            path: path,
            query: query,
            body: (body?.isEmpty ?? true) ? nil : body
        )
    }

    public static func isTagged(_ statement: String) -> Bool {
        statement.hasPrefix(writeTag)
    }
}
