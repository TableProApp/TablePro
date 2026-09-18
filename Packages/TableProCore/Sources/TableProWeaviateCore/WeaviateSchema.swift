import Foundation

public struct WeaviateProperty: Sendable, Equatable {
    public let name: String
    public let dataTypes: [String]
    public let nestedProperties: [WeaviateProperty]

    public var dataType: String { dataTypes.first ?? "text" }

    public init(name: String, dataType: String) {
        self.init(name: name, dataTypes: [dataType], nestedProperties: [])
    }

    public init(name: String, dataTypes: [String], nestedProperties: [WeaviateProperty]) {
        self.name = name
        self.dataTypes = dataTypes.isEmpty ? ["text"] : dataTypes
        self.nestedProperties = nestedProperties
    }

    public static func parse(_ json: [String: Any]) -> WeaviateProperty? {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        let nested = json["nestedProperties"] as? [[String: Any]] ?? []
        return WeaviateProperty(
            name: name,
            dataTypes: json["dataType"] as? [String] ?? [],
            nestedProperties: nested.compactMap(WeaviateProperty.parse)
        )
    }
}

/// A GraphQL field with a structured type is refused without a sub-selection: asking for a
/// `geoCoordinates` property by name answers `Field "place" ... must have a sub selection` and the
/// whole query fails, taking the filtered browse with it.
public enum WeaviatePropertyShape: Sendable, Equatable {
    case scalar
    case geoCoordinates
    case phoneNumber
    case object
    case crossReference([String])

    private static let scalarTypes: Set<String> = [
        "text", "string", "int", "number", "boolean", "bool", "date", "uuid", "blob"
    ]

    public static func of(_ property: WeaviateProperty) -> WeaviatePropertyShape {
        let names = property.dataTypes.map { element($0) }
        guard let first = names.first else { return .scalar }
        if scalarTypes.contains(first.lowercased()) { return .scalar }
        switch first {
        case "geoCoordinates": return .geoCoordinates
        case "phoneNumber": return .phoneNumber
        case "object": return .object
        default:
            return first.first?.isUppercase == true ? .crossReference(names) : .scalar
        }
    }

    private static func element(_ dataType: String) -> String {
        var name = dataType.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("[]") {
            name = String(name.dropLast(2))
        }
        return name
    }
}

public struct WeaviateCollection: Sendable, Equatable {
    public let name: String
    public let properties: [WeaviateProperty]
    public let vectorizer: String?

    public init(name: String, properties: [WeaviateProperty], vectorizer: String? = nil) {
        self.name = name
        self.properties = properties
        self.vectorizer = vectorizer
    }

    public static func parse(_ json: [String: Any]) -> WeaviateCollection? {
        guard let name = json["class"] as? String, !name.isEmpty else { return nil }
        let rawProperties = json["properties"] as? [[String: Any]] ?? []
        let properties = rawProperties.compactMap(WeaviateProperty.parse)
        return WeaviateCollection(
            name: name,
            properties: properties,
            vectorizer: json["vectorizer"] as? String
        )
    }
}

public enum WeaviateSchema {
    public static let uuidColumn = "uuid"
    public static let vectorColumn = "vector"
    public static let immutableColumns: [String] = [uuidColumn, vectorColumn]

    /// Weaviate names the object id `id` inside a `where` or `sort` argument, and normalizes it to
    /// `_id` in its own errors. The grid calls the same column `uuid`.
    public static let uuidGraphQLPath = "id"

    public static func collections(from json: Any) -> [WeaviateCollection] {
        let classes: [[String: Any]]
        if let object = json as? [String: Any] {
            classes = object["classes"] as? [[String: Any]] ?? []
        } else if let array = json as? [[String: Any]] {
            classes = array
        } else {
            return []
        }
        return classes.compactMap(WeaviateCollection.parse)
    }

    public static func columns(for collection: WeaviateCollection) -> [(name: String, type: String, isPrimaryKey: Bool)] {
        var result: [(name: String, type: String, isPrimaryKey: Bool)] = [
            (uuidColumn, "uuid", true)
        ]
        result += collection.properties.map { ($0.name, $0.dataType, false) }
        result.append((vectorColumn, "vector", false))
        return result
    }
}
