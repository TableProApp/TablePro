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
            return .text(json.jsonText())
        }
    }
}
