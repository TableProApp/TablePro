import Foundation

public enum TrinoValue: Sendable, Equatable {
    case null
    case text(String)
    case bytes([UInt8])
}

public enum TrinoValueDecoder {
    public static func decode(_ json: TrinoJSONValue, category: TrinoTypeCategory) -> TrinoValue {
        if json.isNull {
            return .null
        }
        switch category {
        case .scalar:
            return .text(json.scalarText ?? "")
        case .binary:
            if case .string(let encoded) = json, let data = Data(base64Encoded: encoded) {
                return .bytes([UInt8](data))
            }
            return .text(json.scalarText ?? "")
        case .structured:
            return .text(structuredText(json))
        }
    }

    // Presto 0.299 sends array, map and row values as their JSON text rather than as JSON.
    private static func structuredText(_ json: TrinoJSONValue) -> String {
        guard case .string(let text) = json,
              let parsed = try? JSONDecoder().decode(TrinoJSONValue.self, from: Data(text.utf8)) else {
            return json.jsonText()
        }
        switch parsed {
        case .array, .object:
            return parsed.jsonText()
        default:
            return json.jsonText()
        }
    }
}
