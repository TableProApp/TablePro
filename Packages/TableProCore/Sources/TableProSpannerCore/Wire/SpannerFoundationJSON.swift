import Foundation

internal enum SpannerFoundationJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else {
            throw SpannerTransportError.invalidResponse
        }
        return object
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from object: Any?) throws -> Value? {
        guard let object, !(object is NSNull) else { return nil }
        guard JSONSerialization.isValidJSONObject(object) else { throw SpannerTransportError.invalidResponse }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SpannerTransportError.invalidResponse
        }
    }

    static func values(_ object: Any?) throws -> [SpannerJSONValue] {
        guard let object, !(object is NSNull) else { return [] }
        guard let list = object as? NSArray else { throw SpannerTransportError.invalidResponse }
        return list.map(SpannerJSONValue.init(foundationObject:))
    }

    static func rows(_ object: Any?) throws -> [[SpannerJSONValue]] {
        guard let object, !(object is NSNull) else { return [] }
        guard let list = object as? NSArray else { throw SpannerTransportError.invalidResponse }
        return try list.map { try values($0) }
    }

    static func flag(_ object: Any?) -> Bool {
        (object as? NSNumber)?.boolValue ?? false
    }
}

internal extension SpannerJSONValue {
    init(foundationObject: Any) {
        let reference = foundationObject as AnyObject
        if let text = reference as? NSString {
            self = .string(text as String)
        } else if let number = reference as? NSNumber {
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        } else if let list = reference as? NSArray {
            self = .list(list.map(SpannerJSONValue.init(foundationObject:)))
        } else if let object = reference as? NSDictionary {
            var members: [String: SpannerJSONValue] = [:]
            for case (let key as String, let value) in object {
                members[key] = SpannerJSONValue(foundationObject: value)
            }
            self = .object(members)
        } else {
            self = .null
        }
    }
}

internal extension SpannerPartialResultSet {
    init(foundationObject object: [String: Any]) throws {
        self.init(
            metadata: try SpannerFoundationJSON.decode(SpannerResultSetMetadata.self, from: object["metadata"]),
            values: try SpannerFoundationJSON.values(object["values"]),
            chunkedValue: SpannerFoundationJSON.flag(object["chunkedValue"]),
            resumeToken: object["resumeToken"] as? String,
            stats: try SpannerFoundationJSON.decode(SpannerResultSetStats.self, from: object["stats"])
        )
    }
}

internal extension SpannerResultSet {
    init(foundationObject object: [String: Any]) throws {
        self.init(
            metadata: try SpannerFoundationJSON.decode(SpannerResultSetMetadata.self, from: object["metadata"]),
            rows: try SpannerFoundationJSON.rows(object["rows"]),
            stats: try SpannerFoundationJSON.decode(SpannerResultSetStats.self, from: object["stats"])
        )
    }
}
