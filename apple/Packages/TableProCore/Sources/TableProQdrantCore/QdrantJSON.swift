import Foundation

public enum QdrantJSON {
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

    public static func parse(_ text: String) -> Any? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
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
}
