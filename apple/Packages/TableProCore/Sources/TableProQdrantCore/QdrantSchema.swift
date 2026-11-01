import Foundation

// The first seven are Qdrant's payload index schemas; the rest are read off sampled values.
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

    public var holdsText: Bool {
        switch self {
        case .keyword, .text, .string, .uuid, .array, .json: return true
        default: return false
        }
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

    static func elementType(of value: Any?) -> QdrantFieldType? {
        guard let items = value as? [Any] else { return nil }
        return items.compactMap(observed).reduce(nil) { merged, type in merged.map { $0.merged(with: type) } ?? type }
    }

    func stores(_ stored: QdrantFieldType) -> Bool {
        switch self {
        case .keyword, .text, .uuid, .datetime, .string: return stored == .string
        case .integer: return stored == .integer
        case .float: return stored == .float || stored == .integer
        case .bool: return stored == .bool
        case .geo: return stored == .object
        case .object, .array, .json: return stored == self
        }
    }

    func merged(with other: QdrantFieldType) -> QdrantFieldType {
        if self == other { return self }
        if Set([self, other]) == [.integer, .float] { return .float }
        return .json
    }
}

public struct QdrantVectorSpec: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case dense(size: Int?)
        case multi
        case sparse
    }

    // Empty for the collection's unnamed vector, which Qdrant also accepts under the name "".
    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public var column: String {
        name.isEmpty ? QdrantSchema.vectorColumn : "\(QdrantSchema.vectorColumn).\(name)"
    }

    public var typeName: String {
        switch kind {
        case .dense(let size?): return "vector(\(size))"
        case .dense: return "vector"
        case .multi: return "multivector"
        case .sparse: return "sparse_vector"
        }
    }

    public static func kind(ofTypeName typeName: String) -> Kind? {
        let lower = typeName.lowercased().trimmingCharacters(in: .whitespaces)
        switch lower {
        case "sparse_vector": return .sparse
        case "multivector": return .multi
        case "vector": return .dense(size: nil)
        default:
            guard lower.hasPrefix("vector("), lower.hasSuffix(")") else { return nil }
            return .dense(size: Int(lower.dropFirst("vector(".count).dropLast()))
        }
    }

    static func dense(name: String, config: [String: Any]) -> QdrantVectorSpec {
        if config["multivector_config"] is [String: Any] {
            return QdrantVectorSpec(name: name, kind: .multi)
        }
        return QdrantVectorSpec(name: name, kind: .dense(size: config["size"] as? Int))
    }
}

public struct QdrantPayloadField: Sendable, Equatable {
    public let name: String
    // The index's type for an indexed field, which filters use; the sampled type otherwise.
    public let type: QdrantFieldType
    public let isIndexed: Bool
    // False while every sampled value was null, so the first real value sets the type outright.
    public let hasTypedValue: Bool
    // What an indexed field's points actually store, which the index does not constrain: a keyword
    // index still lets a point hold 42 or a list. Lists are indexed element by element.
    public let scalarType: QdrantFieldType?
    public let elementType: QdrantFieldType?
    public let holdsLists: Bool

    public init(
        name: String,
        type: QdrantFieldType,
        isIndexed: Bool,
        hasTypedValue: Bool = true,
        scalarType: QdrantFieldType? = nil,
        elementType: QdrantFieldType? = nil,
        holdsLists: Bool = false
    ) {
        self.name = name
        self.type = type
        self.isIndexed = isIndexed
        self.hasTypedValue = hasTypedValue
        self.scalarType = scalarType
        self.elementType = elementType
        self.holdsLists = holdsLists
    }

    public var storedType: QdrantFieldType? {
        guard holdsLists else { return scalarType }
        return scalarType == nil ? .array : .json
    }

    // Whether the index covers every value seen, so a filter typed by it finds them all.
    public var fitsIndex: Bool {
        guard isIndexed else { return false }
        return (scalarType.map(type.stores) ?? true) && (elementType.map(type.stores) ?? true)
    }

    // What a cell holds and is written back as, so a value saves as the type it was stored with.
    // The index's name stands in only when every value seen fits it.
    public var cellTypeName: String {
        guard isIndexed, let storedType else { return type.rawValue }
        return type.stores(storedType) ? type.rawValue : storedType.rawValue
    }
}

public struct QdrantPayloadIndex: Sendable, Equatable {
    public let path: String
    public let type: String

    public init(path: String, type: String) {
        self.path = path
        self.type = type
    }
}

public struct QdrantCollection: Sendable, Equatable {
    public let name: String
    public let vectors: [QdrantVectorSpec]
    public let payloadFields: [QdrantPayloadField]
    public let indexes: [QdrantPayloadIndex]
    public let pointsCount: Int?
    public let info: String

    public init(
        name: String,
        vectors: [QdrantVectorSpec],
        payloadFields: [QdrantPayloadField],
        indexes: [QdrantPayloadIndex] = [],
        pointsCount: Int? = nil,
        info: String = "{}"
    ) {
        self.name = name
        self.vectors = vectors
        self.payloadFields = payloadFields
        self.indexes = indexes
        self.pointsCount = pointsCount
        self.info = info
    }

    // Only an index states a field's type; a sample guesses it from 100 points.
    // An index does not constrain what points store, so it types a filter only while every value seen
    // fits it; a keyword index holding 42 in some point filters like a field nobody indexed.
    public func indexType(ofColumn column: String) -> QdrantFieldType? {
        guard let field = field(ofColumn: column), field.fitsIndex else { return nil }
        return field.type
    }

    public func cellTypeName(ofColumn column: String) -> String? {
        field(ofColumn: column)?.cellTypeName
    }

    // `id`, `score` and the vectors are the point's own; a payload key of that name is `payload.<key>`.
    private func field(ofColumn column: String) -> QdrantPayloadField? {
        guard !QdrantSchema.isPointColumn(column) else { return nil }
        let key = QdrantSchema.payloadKey(forColumn: column)
        return payloadFields.first { $0.name == key }
    }

    // A page's points widen the types a sample guessed, so a list first seen on page 2 is not saved as
    // text. `addingKeys` is false for a grid page, whose columns stay the ones the table opened with.
    public func including(_ points: [QdrantPoint], addingKeys: Bool = true) -> QdrantCollection {
        var fields = payloadFields
        var position = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($1.name, $0) })
        for point in points {
            for key in point.payloadKeys {
                let observed = point.payload[key].flatMap(QdrantFieldType.observed)
                guard let index = position[key] else {
                    guard addingKeys else { continue }
                    position[key] = fields.count
                    fields.append(QdrantPayloadField(
                        name: key, type: observed ?? .json, isIndexed: false, hasTypedValue: observed != nil
                    ))
                    continue
                }
                let field = fields[index]
                guard let observed else { continue }
                if field.isIndexed {
                    let isList = observed == .array
                    let elements = isList ? QdrantFieldType.elementType(of: point.payload[key]) : nil
                    fields[index] = QdrantPayloadField(
                        name: key, type: field.type, isIndexed: true,
                        scalarType: isList ? field.scalarType : field.scalarType.map { $0.merged(with: observed) } ?? observed,
                        elementType: [field.elementType, elements].compactMap { $0 }.reduce(nil) { merged, next in
                            merged.map { $0.merged(with: next) } ?? next
                        },
                        holdsLists: field.holdsLists || isList
                    )
                    continue
                }
                let type = field.hasTypedValue ? field.type.merged(with: observed) : observed
                fields[index] = QdrantPayloadField(name: key, type: type, isIndexed: false)
            }
        }
        return QdrantCollection(
            name: name, vectors: vectors, payloadFields: fields, indexes: indexes, pointsCount: pointsCount, info: info
        )
    }

    // `payload_schema` keys are JSON paths: only a top-level key is a column, while a nested path such as
    // `metadata.source` or `tags[]` stays an index on the column that holds it.
    public static func parse(name: String, info json: Any?, sample: [QdrantPoint] = []) -> QdrantCollection {
        let result = (json as? [String: Any])?["result"] as? [String: Any] ?? [:]
        let params = ((result["config"] as? [String: Any])?["params"] as? [String: Any]) ?? [:]

        var vectors: [QdrantVectorSpec] = []
        if let config = params["vectors"] as? [String: Any] {
            // A named vector may itself be called `size`; only the unnamed one has a number there.
            if config["size"] is NSNumber {
                vectors.append(.dense(name: "", config: config))
            } else {
                vectors += config.keys.sorted().map { key in
                    .dense(name: key, config: config[key] as? [String: Any] ?? [:])
                }
            }
        }
        if let sparse = params["sparse_vectors"] as? [String: Any] {
            vectors += sparse.keys.sorted().map { QdrantVectorSpec(name: $0, kind: .sparse) }
        }

        let schema = result["payload_schema"] as? [String: Any] ?? [:]
        var indexes: [QdrantPayloadIndex] = []
        var fields: [QdrantPayloadField] = []
        for path in schema.keys.sorted() {
            guard let type = QdrantFieldType.indexed(schema[path]) else { continue }
            indexes.append(QdrantPayloadIndex(path: path, type: type.rawValue))
            if let key = QdrantKeyPath.topLevelKey(ofIndexPath: path), !fields.contains(where: { $0.name == key }) {
                fields.append(QdrantPayloadField(name: key, type: type, isIndexed: true))
            }
        }

        return QdrantCollection(
            name: name,
            vectors: vectors,
            payloadFields: fields,
            indexes: indexes,
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
    static let payloadPrefix = "payload."

    public static func collectionNames(from json: Any?) -> [String] {
        let result = (json as? [String: Any])?["result"] as? [String: Any]
        let collections = result?["collections"] as? [[String: Any]] ?? []
        return collections.compactMap { $0["name"] as? String }.sorted()
    }

    public static func isPointColumn(_ column: String) -> Bool {
        column == idColumn || column == scoreColumn || isVectorColumn(column)
    }

    public static func isVectorColumn(_ column: String) -> Bool {
        column == vectorColumn || column.hasPrefix("\(vectorColumn).")
    }

    public static func vectorName(ofColumn column: String) -> String? {
        if column == vectorColumn { return "" }
        guard column.hasPrefix("\(vectorColumn).") else { return nil }
        return String(column.dropFirst(vectorColumn.count + 1))
    }

    // A payload key named `id`, `score` or `vector...` would take a point column's name, so it shows as
    // `payload.<key>`. A key already starting with `payload.` is prefixed too, so every column maps back
    // to exactly one key.
    public static func isReserved(_ key: String) -> Bool {
        key == idColumn || key == scoreColumn || isVectorColumn(key) || key.hasPrefix(payloadPrefix)
    }

    public static func column(forPayloadKey key: String) -> String {
        isReserved(key) ? payloadPrefix + key : key
    }

    public static func payloadKey(forColumn column: String) -> String {
        column.hasPrefix(payloadPrefix) ? String(column.dropFirst(payloadPrefix.count)) : column
    }

    public static func columns(for collection: QdrantCollection) -> [QdrantColumn] {
        var columns = [QdrantColumn(name: idColumn, type: "id", isPrimaryKey: true)]
        columns += collection.payloadFields.map {
            QdrantColumn(name: column(forPayloadKey: $0.name), type: $0.cellTypeName, isPrimaryKey: false)
        }
        columns += collection.vectors.map { QdrantColumn(name: $0.column, type: $0.typeName, isPrimaryKey: false) }
        return columns
    }

    public static func typeName(of column: String, in collection: QdrantCollection) -> String {
        if column == scoreColumn { return QdrantFieldType.float.rawValue }
        if let known = knownTypeName(of: column, in: collection) { return known }
        return isVectorColumn(column) ? "vector" : QdrantFieldType.json.rawValue
    }

    public static func knownTypeName(of column: String, in collection: QdrantCollection) -> String? {
        if column == idColumn { return "id" }
        if let spec = collection.vectors.first(where: { $0.column == column }) {
            return spec.typeName
        }
        return collection.cellTypeName(ofColumn: column)
    }
}

public enum QdrantKeyPath {
    // Qdrant reads a filter key as a JSON path, so `a.b` would address a nested field. Quoting keeps
    // any top-level key whole; a key holding a double quote has no spelling Qdrant accepts.
    public static func quoted(_ key: String) -> String? {
        guard !key.contains("\"") else { return nil }
        return "\"\(key)\""
    }

    public static func topLevelKey(ofIndexPath path: String) -> String? {
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            let inner = path.dropFirst().dropLast()
            return inner.contains("\"") ? nil : String(inner)
        }
        return path.contains(where: { ".[]\"".contains($0) }) ? nil : path
    }
}
