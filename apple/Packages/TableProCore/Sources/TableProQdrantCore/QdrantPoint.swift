import Foundation

public enum QdrantPointID {
    // Qdrant refuses an integer id spelled as a string and the other way round.
    public static func json(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber), let number = UInt64(trimmed) {
            return NSNumber(value: number)
        }
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return trimmed.lowercased()
    }
}

public struct QdrantPoint: @unchecked Sendable {
    public let id: Any?
    public let payload: [String: Any]
    // Nil when the request left vectors out, an array for an unnamed vector alone, a map by name otherwise.
    public let vector: Any?
    public let score: Double?

    public init(id: Any?, payload: [String: Any], vector: Any?, score: Double?) {
        self.id = id
        self.payload = payload
        self.vector = vector
        self.score = score
    }

    public var idText: String? { QdrantJSON.displayText(id) }

    public var payloadKeys: [String] { payload.keys.sorted() }

    public static func parse(_ json: Any) -> QdrantPoint? {
        guard let object = json as? [String: Any], object.keys.contains("id") else { return nil }
        let vector = object["vector"] ?? object["vectors"]
        return QdrantPoint(
            id: object["id"],
            payload: object["payload"] as? [String: Any] ?? [:],
            vector: vector is NSNull ? nil : vector,
            score: (object["score"] as? NSNumber)?.doubleValue
        )
    }

    // `scroll` and `query` wrap the list in `points`; retrieve and `search` answer the array itself.
    public static func list(fromResponse json: Any?) -> [QdrantPoint]? {
        guard let result = (json as? [String: Any])?["result"] else { return nil }
        let items: [Any]
        if let wrapped = (result as? [String: Any])?["points"] as? [Any] {
            items = wrapped
        } else if let array = result as? [Any] {
            items = array
        } else {
            return nil
        }
        let points = items.compactMap(parse)
        return points.count == items.count ? points : nil
    }

    public func vectorValue(forColumn column: String) -> Any? {
        guard let vector, let name = QdrantSchema.vectorName(ofColumn: column) else { return nil }
        if name.isEmpty, vector is [Any] { return vector }
        return (vector as? [String: Any])?[name]
    }

    public func cell(for column: String) -> String? {
        if column == QdrantSchema.idColumn {
            return idText
        }
        if QdrantSchema.isVectorColumn(column) {
            return QdrantJSON.displayText(vectorValue(forColumn: column))
        }
        if column == QdrantSchema.scoreColumn {
            return score.map { String($0) }
        }
        return QdrantJSON.displayText(payload[QdrantSchema.payloadKey(forColumn: column)])
    }

    public func row(columns: [String]) -> [String?] {
        columns.map(cell(for:))
    }

    public static func columns(of points: [QdrantPoint], collection: QdrantCollection?) -> [String] {
        var columns = [QdrantSchema.idColumn]
        if points.contains(where: { $0.score != nil }) {
            columns.append(QdrantSchema.scoreColumn)
        }
        let returned = Set(points.flatMap(\.payloadKeys).map(QdrantSchema.column(forPayloadKey:)))
        let declared = collection?.payloadFields.map { QdrantSchema.column(forPayloadKey: $0.name) } ?? []
        columns += declared.filter { returned.contains($0) && !columns.contains($0) }
        columns += returned.subtracting(declared).subtracting(columns).sorted()

        var vectorColumns: Set<String> = []
        for point in points {
            if point.vector is [Any] {
                vectorColumns.insert(QdrantSchema.vectorColumn)
            } else if let named = point.vector as? [String: Any] {
                vectorColumns.formUnion(named.keys.map { QdrantVectorSpec(name: $0, kind: .dense(size: nil)).column })
            }
        }
        return columns + vectorColumns.subtracting(columns).sorted()
    }
}
