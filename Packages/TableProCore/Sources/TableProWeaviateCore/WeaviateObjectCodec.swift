import Foundation

public struct WeaviateObject: Sendable, Equatable {
    public let uuid: String
    public let className: String
    public let properties: [String: String?]
    public let vector: [Double]?

    public init(uuid: String, className: String, properties: [String: String?], vector: [Double]?) {
        self.uuid = uuid
        self.className = className
        self.properties = properties
        self.vector = vector
    }

    public static func parse(_ json: [String: Any]) -> WeaviateObject? {
        let uuid = (json["id"] as? String) ?? ""
        let className = (json["class"] as? String) ?? ""
        let raw = json["properties"] as? [String: Any] ?? [:]
        var properties: [String: String?] = [:]
        for (key, value) in raw {
            properties[key] = WeaviateJSON.displayText(value)
        }
        let vector = vector(from: json["vector"])
        if uuid.isEmpty, properties.isEmpty, vector == nil {
            return nil
        }
        return WeaviateObject(uuid: uuid, className: className, properties: properties, vector: vector)
    }

    public static func parseList(_ json: Any) -> [WeaviateObject] {
        let objects: [[String: Any]]
        if let object = json as? [String: Any] {
            objects = object["objects"] as? [[String: Any]] ?? []
        } else if let array = json as? [[String: Any]] {
            objects = array
        } else {
            return []
        }
        return objects.compactMap(parse)
    }

    public var vectorText: String? {
        guard let vector, !vector.isEmpty else {
            return vector == nil ? nil : "[]"
        }
        return "[" + vector.map(Self.numberText).joined(separator: ",") + "]"
    }

    private static func numberText(_ value: Double) -> String {
        if value.rounded() == value, let whole = Int(exactly: value) {
            return String(whole)
        }
        return String(value)
    }

    static func vector(from value: Any?) -> [Double]? {
        if let numbers = value as? [Double] {
            return numbers
        }
        if let numbers = value as? [NSNumber] {
            return numbers.map(\.doubleValue)
        }
        return nil
    }
}

public enum WeaviateObjectCodec {
    static let additionalKey = "_additional"

    public static func row(for object: WeaviateObject, columns: [String]) -> [String?] {
        columns.map { column in
            switch column {
            case WeaviateSchema.uuidColumn:
                return object.uuid.isEmpty ? nil : object.uuid
            case WeaviateSchema.vectorColumn:
                return object.vectorText
            default:
                if let value = object.properties[column] {
                    return value
                }
                return nil
            }
        }
    }

    public static func objects(fromGraphQL json: Any) -> [WeaviateObject] {
        guard let root = json as? [String: Any] else { return [] }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            return []
        }
        guard let data = root["data"] as? [String: Any] else { return [] }
        if let get = data["Get"] as? [String: Any] {
            return objects(fromGet: get)
        }
        return []
    }

    public static func graphQLErrors(from json: Any) -> [String] {
        guard let root = json as? [String: Any],
              let errors = root["errors"] as? [[String: Any]]
        else { return [] }
        return errors.compactMap { $0["message"] as? String }.filter { !$0.isEmpty }
    }

    private static func objects(fromGet get: [String: Any]) -> [WeaviateObject] {
        var result: [WeaviateObject] = []
        for (className, value) in get {
            guard let rows = value as? [[String: Any]] else { continue }
            for row in rows {
                result.append(object(fromGetRow: row, className: className))
            }
        }
        return result
    }

    /// `_additional` is where a vector search puts `distance`, `score` and `certainty`, which are
    /// the whole point of the query the user wrote. Only `id` and `vector` have a column of their
    /// own; the rest become properties so they reach the grid.
    private static func object(fromGetRow row: [String: Any], className: String) -> WeaviateObject {
        var properties: [String: String?] = [:]
        var additional: [String: Any] = [:]
        var uuid = ""
        var vector: [Double]?
        for (key, value) in row {
            if key == additionalKey, let fields = value as? [String: Any] {
                additional = fields
                continue
            }
            properties[key] = WeaviateJSON.displayText(value)
        }
        uuid = (additional["id"] as? String) ?? uuid
        vector = WeaviateObject.vector(from: additional["vector"])
        for (key, value) in additional where key != "id" && key != WeaviateSchema.vectorColumn {
            let name = properties[key] == nil ? key : "\(additionalKey).\(key)"
            properties[name] = WeaviateJSON.displayText(value)
        }
        return WeaviateObject(uuid: uuid, className: className, properties: properties, vector: vector)
    }
}
