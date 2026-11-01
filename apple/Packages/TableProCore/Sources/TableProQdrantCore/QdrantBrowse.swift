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
    public let sorts: [QdrantSortSpec]
    public let filters: [QdrantFilterSpec]
    public let logicMode: String

    public init(
        collection: String,
        offset: Int,
        limit: Int,
        sorts: [QdrantSortSpec],
        filters: [QdrantFilterSpec],
        logicMode: String
    ) {
        self.collection = collection
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
        self.sorts = sorts
        self.filters = filters
        self.logicMode = logicMode
    }
}

// The page is built before the driver knows the field types the filter JSON depends on, so it travels
// from `buildFilteredQuery` to `execute` as tagged text.
public enum QdrantBrowseQuery {
    public static let tag = "QDRANT_BROWSE:"

    public static func encode(_ request: QdrantBrowseRequest) -> String {
        let payload: [String: Any] = [
            "collection": request.collection,
            "offset": request.offset,
            "limit": request.limit,
            "logicMode": request.logicMode,
            "sorts": request.sorts.map { ["column": $0.column, "ascending": $0.ascending] },
            "filters": request.filters.map { filter -> [String: Any] in
                var encoded: [String: Any] = ["column": filter.column, "op": filter.op, "value": filter.value]
                if let secondValue = filter.secondValue {
                    encoded["secondValue"] = secondValue
                }
                return encoded
            }
        ]
        let body = (try? QdrantJSON.data(payload)) ?? Data()
        return tag + body.base64EncodedString()
    }

    public static func parse(_ query: String) -> QdrantBrowseRequest? {
        guard query.hasPrefix(tag),
              let data = Data(base64Encoded: String(query.dropFirst(tag.count))),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collection = json["collection"] as? String
        else { return nil }
        let sorts = (json["sorts"] as? [[String: Any]] ?? []).compactMap { item -> QdrantSortSpec? in
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
            sorts: sorts,
            filters: filters,
            logicMode: json["logicMode"] as? String ?? "AND"
        )
    }
}

public enum QdrantSortPlan: Sendable, Equatable {
    case byID
    case byPayload(column: String, key: String, ascending: Bool)

    public static func resolve(_ sorts: [QdrantSortSpec]) throws -> QdrantSortPlan {
        guard let sort = sorts.first else { return .byID }
        guard sorts.count == 1 else {
            throw QdrantError.unsupported(String(localized: "Qdrant sorts by one field at a time. Remove the sort from the other columns."))
        }
        if sort.column == QdrantSchema.idColumn {
            guard sort.ascending else {
                throw QdrantError.unsupported(String(localized: "Qdrant lists points by id in ascending order only."))
            }
            return .byID
        }
        guard !QdrantSchema.isVectorColumn(sort.column), sort.column != QdrantSchema.scoreColumn else {
            throw QdrantError.unsupported(String(format: String(localized: "Qdrant cannot sort by %@."), sort.column))
        }
        guard let key = QdrantKeyPath.quoted(QdrantSchema.payloadKey(forColumn: sort.column)) else {
            throw QdrantFilterError.keyNotAddressable(column: sort.column)
        }
        return .byPayload(column: sort.column, key: key, ascending: sort.ascending)
    }
}
