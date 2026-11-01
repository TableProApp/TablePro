import Foundation

// `order_by` walks Qdrant's range index, which holds only points with a value in it and holds a point
// once per value. So the grid's rows are the ordered points first, then the points without a value in
// id order, and a field holding a list in some point is refused: no offset can page it one row per point.
public extension QdrantClient {
    func sortedPage(
        collection: String,
        filter: [String: Any]?,
        column: String,
        key: String,
        ascending: Bool,
        offset: Int,
        limit: Int,
        cache: QdrantPagingCache
    ) async throws -> [QdrantPoint] {
        let hasValue: [String: Any] = ["key": key, "range": [String: Any]()]
        let ordered = QdrantFilterBuilder.allOf(filter, hasValue)

        let checkKey = "\(collection)\u{0}\(key)\u{0}\((try? QdrantJSON.text(ordered)) ?? "")"
        if !cache.isSortChecked(checkKey) {
            let listed = try await count(
                collection: collection,
                filter: QdrantFilterBuilder.allOf(ordered, ["key": key, "values_count": ["gt": 1]])
            )
            guard listed == 0 else {
                throw QdrantError.unsupported(String(
                    format: String(localized: "%@ holds a list in %d points, and Qdrant sorts such a point once per value. Sort by a field that holds one value per point."),
                    column, listed
                ))
            }
            cache.markSortChecked(checkKey)
        }

        let orderedCount = try await count(collection: collection, filter: ordered)
        var points: [QdrantPoint] = []
        if offset < orderedCount {
            var body: [String: Any] = [
                "query": ["order_by": ["key": key, "direction": ascending ? "asc" : "desc"]],
                "limit": min(limit, orderedCount - offset),
                "offset": offset,
                "with_payload": true,
                "with_vector": true
            ]
            if let filter {
                body["filter"] = filter
            }
            points = try await query(collection: collection, body: body)
        }
        guard points.count < limit else { return points }
        let withoutValue = QdrantFilterBuilder.allOf(filter, QdrantFilterBuilder.negated([hasValue]))
        return points + (try await scrollPage(
            collection: collection,
            filter: withoutValue,
            offset: max(offset - orderedCount, 0),
            limit: limit - points.count,
            cache: cache
        ))
    }
}
