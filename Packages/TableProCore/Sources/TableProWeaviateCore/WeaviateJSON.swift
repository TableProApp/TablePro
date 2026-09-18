import Foundation

public enum WeaviateJSON {
    public static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    public static func data(_ object: Any, pretty: Bool = false) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw WeaviateError.malformedResponse(String(localized: "Request body is not valid JSON."))
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty {
            options.insert(.prettyPrinted)
        }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    public static func text(_ object: Any, pretty: Bool = false) throws -> String {
        let encoded = try data(object, pretty: pretty)
        return String(data: encoded, encoding: .utf8) ?? "{}"
    }

    public static func displayText(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let text as String:
            return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let object as [String: Any]:
            return (try? text(object)) ?? nil
        case let object as [Any]:
            return (try? text(object)) ?? nil
        default:
            return String(describing: value as Any)
        }
    }

    /// Only a property the grid renders as JSON is parsed back as JSON. Running the parser over
    /// every type sends a `text` cell holding `{"a":1}` as an object, which Weaviate rejects while
    /// the grid reports the save.
    public static func parsedValue(_ text: String, typeName: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let declared = typeName.trimmingCharacters(in: .whitespaces)
        let isArray = declared.hasSuffix("[]")
        if !isArray {
            switch WeaviateValueKind.forDataType(declared) {
            case .boolean:
                if trimmed.lowercased() == "true" { return true }
                if trimmed.lowercased() == "false" { return false }
                return text
            case .int:
                return Int(trimmed) ?? text
            case .number:
                return Double(trimmed) ?? text
            case .text, .uuid, .date:
                break
            }
        }
        let shape = WeaviatePropertyShape.of(WeaviateProperty(name: "", dataType: declared))
        guard isArray || shape != .scalar else { return text }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              parsed is [Any] || parsed is [String: Any]
        else { return text }
        return parsed
    }
}
