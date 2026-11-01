import Foundation

/// The type a payload column holds. The first seven are Qdrant's payload index schemas; the rest
/// are read off sampled values for a field nobody indexed.
public enum QdrantFieldType: String, Sendable, Equatable, CaseIterable {
    case keyword
    case integer
    case float
    case bool
    case geo
    case text
    case datetime
    case uuid
    case string
    case object
    case array
    case json

    public var isOrdered: Bool {
        self == .integer || self == .float || self == .datetime
    }

    public static func indexed(_ schema: Any?) -> QdrantFieldType? {
        let name: String?
        if let object = schema as? [String: Any] {
            name = object["data_type"] as? String
                ?? (object["params"] as? [String: Any])?["type"] as? String
        } else {
            name = schema as? String
        }
        return name.flatMap { QdrantFieldType(rawValue: $0.lowercased()) }
    }

    public static func observed(_ value: Any) -> QdrantFieldType? {
        switch value {
        case is NSNull:
            return nil
        case is String:
            return .string
        case let number as NSNumber:
            if QdrantJSON.isBoolean(number) { return .bool }
            return CFNumberIsFloatType(number) ? .float : .integer
        case is [String: Any]:
            return .object
        case is [Any]:
            return .array
        default:
            return .json
        }
    }

    /// An integer column that also holds a fraction reads as a float; anything else that disagrees is
    /// mixed JSON, written back as whatever the cell parses to.
    func merged(with other: QdrantFieldType) -> QdrantFieldType {
        if self == other { return self }
        if Set([self, other]) == [.integer, .float] { return .float }
        return .json
    }
}

public struct QdrantVectorSpec: Sendable, Equatable {
    /// `nil` for the collection's single unnamed vector.
    public let name: String?
    public let isSparse: Bool

    public init(name: String?, isSparse: Bool = false) {
        self.name = name
        self.isSparse = isSparse
    }

    public var column: String {
        name.map { "\(QdrantSchema.vectorColumn).\($0)" } ?? QdrantSchema.vectorColumn
    }
}

public struct QdrantPayloadField: Sendable, Equatable {
    public let name: String
    public let type: QdrantFieldType
    public let isIndexed: Bool
    /// False while every value seen was null, so the first real value sets the type outright.
    public let hasTypedValue: Bool

    public init(name: String, type: QdrantFieldType, isIndexed: Bool, hasTypedValue: Bool = true) {
        self.name = name
        self.type = type
        self.isIndexed = isIndexed
        self.hasTypedValue = hasTypedValue
    }
}

public struct QdrantCollection: Sendable, Equatable {
    public let name: String
    public let vectors: [QdrantVectorSpec]
    public let payloadFields: [QdrantPayloadField]
    public let pointsCount: Int?
    public let info: String

    public init(
        name: String,
        vectors: [QdrantVectorSpec],
        payloadFields: [QdrantPayloadField],
        pointsCount: Int? = nil,
        info: String = "{}"
    ) {
        self.name = name
        self.vectors = vectors
        self.payloadFields = payloadFields
        self.pointsCount = pointsCount
        self.info = info
    }

    public func fieldType(of column: String) -> QdrantFieldType? {
        let key = QdrantSchema.payloadKey(forColumn: column)
        return payloadFields.first { $0.name == key }?.type
    }

    public var vectorColumns: [String] { vectors.map(\.column) }

    /// The collection with every payload key `points` hold that it lacks, typed by their values. An
    /// indexed field keeps the index's type.
    public func including(_ points: [QdrantPoint]) -> QdrantCollection {
        var fields = payloadFields
        var position = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($1.name, $0) })
        for point in points {
            for key in point.payloadKeys {
                let observed = point.payload[key].flatMap(QdrantFieldType.observed)
                guard let index = position[key] else {
                    position[key] = fields.count
                    fields.append(QdrantPayloadField(
                        name: key, type: observed ?? .json, isIndexed: false, hasTypedValue: observed != nil
                    ))
                    continue
                }
                let field = fields[index]
                guard !field.isIndexed, let observed else { continue }
                let type = field.hasTypedValue ? field.type.merged(with: observed) : observed
                fields[index] = QdrantPayloadField(name: key, type: type, isIndexed: false)
            }
        }
        return QdrantCollection(name: name, vectors: vectors, payloadFields: fields, pointsCount: pointsCount, info: info)
    }

    /// `GET /collections/{name}` answers the config and the indexed payload fields; the fields nobody
    /// indexed are only visible in the points themselves, so a sample of them fills the rest in.
    public static func parse(name: String, info json: Any?, sample: [QdrantPoint]) -> QdrantCollection {
        let result = (json as? [String: Any])?["result"] as? [String: Any] ?? [:]
        let params = ((result["config"] as? [String: Any])?["params"] as? [String: Any]) ?? [:]

        var vectors: [QdrantVectorSpec] = []
        if let named = params["vectors"] as? [String: Any] {
            if named["size"] != nil {
                vectors.append(QdrantVectorSpec(name: nil))
            } else {
                vectors += named.keys.sorted().map { QdrantVectorSpec(name: $0) }
            }
        }
        if let sparse = params["sparse_vectors"] as? [String: Any] {
            vectors += sparse.keys.sorted().map { QdrantVectorSpec(name: $0, isSparse: true) }
        }

        let indexed = result["payload_schema"] as? [String: Any] ?? [:]
        let fields = indexed.keys.sorted().compactMap { key in
            QdrantFieldType.indexed(indexed[key]).map { QdrantPayloadField(name: key, type: $0, isIndexed: true) }
        }

        return QdrantCollection(
            name: name,
            vectors: vectors,
            payloadFields: fields,
            pointsCount: result["points_count"] as? Int,
            info: (try? QdrantJSON.text(result, pretty: true)) ?? "{}"
        ).including(sample)
    }
}

public struct QdrantColumn: Sendable, Equatable {
    public let name: String
    public let type: String
    public let isPrimaryKey: Bool
}

public enum QdrantSchema {
    public static let idColumn = "id"
    public static let vectorColumn = "vector"
    public static let scoreColumn = "score"

    public static func collectionNames(from json: Any?) -> [String] {
        let result = (json as? [String: Any])?["result"] as? [String: Any]
        let collections = result?["collections"] as? [[String: Any]] ?? []
        return collections.compactMap { $0["name"] as? String }.sorted()
    }

    public static func isVectorColumn(_ column: String) -> Bool {
        column == vectorColumn || column.hasPrefix("\(vectorColumn).")
    }

    static let payloadPrefix = "payload."

    /// A payload key may be `id`, `score` or `vector`, which name the point's own columns, so such a
    /// key shows as `payload.<key>` and maps back to its key wherever a column is read or written.
    public static func isReserved(_ key: String) -> Bool {
        key == idColumn || key == scoreColumn || isVectorColumn(key)
    }

    public static func column(forPayloadKey key: String) -> String {
        isReserved(key) ? payloadPrefix + key : key
    }

    public static func payloadKey(forColumn column: String) -> String {
        guard column.hasPrefix(payloadPrefix) else { return column }
        let key = String(column.dropFirst(payloadPrefix.count))
        return isReserved(key) ? key : column
    }

    public static func immutableColumns(for collection: QdrantCollection) -> [String] {
        [idColumn] + collection.vectorColumns
    }

    public static func columns(for collection: QdrantCollection) -> [QdrantColumn] {
        var columns = [QdrantColumn(name: idColumn, type: "id", isPrimaryKey: true)]
        columns += collection.payloadFields.map {
            QdrantColumn(name: column(forPayloadKey: $0.name), type: $0.type.rawValue, isPrimaryKey: false)
        }
        columns += collection.vectors.map {
            QdrantColumn(name: $0.column, type: $0.isSparse ? "sparse_vector" : "vector", isPrimaryKey: false)
        }
        return columns
    }

    public static func typeName(of column: String, in collection: QdrantCollection) -> String {
        if column == idColumn { return "id" }
        if column == scoreColumn { return "float" }
        if let spec = collection.vectors.first(where: { $0.column == column }) {
            return spec.isSparse ? "sparse_vector" : "vector"
        }
        if isVectorColumn(column) { return "vector" }
        return collection.fieldType(of: column)?.rawValue ?? QdrantFieldType.json.rawValue
    }
}
