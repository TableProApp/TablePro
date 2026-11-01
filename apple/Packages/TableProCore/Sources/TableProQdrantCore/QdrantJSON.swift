import Foundation

public enum QdrantJSON {
    public static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    public static func data(_ object: Any, pretty: Bool = false) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw QdrantError.malformedResponse(String(localized: "Request body is not valid JSON."))
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty {
            options.insert(.prettyPrinted)
        }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    public static func text(_ object: Any, pretty: Bool = false) throws -> String {
        String(data: try data(object, pretty: pretty), encoding: .utf8) ?? "{}"
    }

    public static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    public static func displayText(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let text as String:
            return text
        case let number as NSNumber:
            if isBoolean(number) {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let object as [String: Any]:
            return try? text(object)
        case let array as [Any]:
            return try? text(array)
        default:
            return String(describing: value as Any)
        }
    }

    /// A payload is schemaless, so a cell is written back as the type its column holds. Parsing every
    /// cell as JSON would turn a string field holding `42` into a number and break a `match` on it.
    public static func parsedValue(_ text: String, fieldType: QdrantFieldType) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch fieldType {
        case .keyword, .text, .string, .uuid, .datetime:
            return text
        case .integer:
            return Int64(trimmed) ?? Double(trimmed).map { $0 as Any } ?? text
        case .float:
            return Double(trimmed) ?? text
        case .bool:
            switch trimmed.lowercased() {
            case "true": return true
            case "false": return false
            default: return text
            }
        case .geo, .object, .array, .json:
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return text }
            return parsed
        }
    }
}
