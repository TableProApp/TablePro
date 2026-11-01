import Foundation

/// A point id is an unsigned integer or a UUID, and Qdrant refuses one in the other's form, so the
/// grid's text is turned back into the kind it came from.
public enum QdrantPointID {
    public static func json(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber), let number = UInt64(trimmed) {
            return NSNumber(value: number)
        }
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return trimmed.lowercased()
    }

    public static func text(_ value: Any?) -> String? {
        QdrantJSON.displayText(value)
    }
}

public struct QdrantPoint: @unchecked Sendable {
    public let id: Any?
    public let payload: [String: Any]
    /// `nil` when the request left vectors out; an array for an unnamed vector; a map by name otherwise.
    public let vector: Any?
    public let score: Double?

    public init(id: Any?, payload: [String: Any], vector: Any?, score: Double?) {
        self.id = id
        self.payload = payload
        self.vector = vector
        self.score = score
    }

    public var idText: String? { QdrantPointID.text(id) }

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

    /// The point list of any read endpoint: `scroll` and `query` wrap it in `points`, retrieve and the
    /// older `search` answer the array itself. `nil` when the result is not a list of points.
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

    public func vectorValue(for column: String) -> Any? {
        guard let vector else { return nil }
        if column == QdrantSchema.vectorColumn {
            if vector is [Any] { return vector }
            return (vector as? [String: Any])?[""]
        }
        let name = String(column.dropFirst(QdrantSchema.vectorColumn.count + 1))
        return (vector as? [String: Any])?[name]
    }

    public func cell(for column: String) -> String? {
        if column == QdrantSchema.idColumn {
            return idText
        }
        if QdrantSchema.isVectorColumn(column) {
            return QdrantJSON.displayText(vectorValue(for: column))
        }
        if column == QdrantSchema.scoreColumn {
            return score.map { String($0) }
        }
        return QdrantJSON.displayText(payload[QdrantSchema.payloadKey(forColumn: column)])
    }

    public func row(columns: [String]) -> [String?] {
        columns.map(cell(for:))
    }

    /// The columns a console result shows: what came back, in the order the collection lists it.
    public static func columns(of points: [QdrantPoint], collection: QdrantCollection?) -> [String] {
        var columns = [QdrantSchema.idColumn]
        if points.contains(where: { $0.score != nil }) {
            columns.append(QdrantSchema.scoreColumn)
        }
        let returned = Set(points.flatMap(\.payloadKeys).map(QdrantSchema.column(forPayloadKey:)))
        let declared = collection?.payloadFields.map { QdrantSchema.column(forPayloadKey: $0.name) } ?? []
        columns += declared.filter { returned.contains($0) && !columns.contains($0) }
        columns += returned.subtracting(declared).subtracting(columns).sorted()

        var vectorColumns: [String] = []
        for point in points {
            if point.vector is [Any] {
                vectorColumns.append(QdrantSchema.vectorColumn)
            } else if let named = point.vector as? [String: Any] {
                vectorColumns += named.keys.map { "\(QdrantSchema.vectorColumn).\($0)" }
            }
        }
        var seen = Set(columns)
        for column in vectorColumns.sorted() where seen.insert(column).inserted {
            columns.append(column)
        }
        return columns
    }
}
