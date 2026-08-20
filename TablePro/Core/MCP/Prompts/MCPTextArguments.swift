import Foundation

public enum MCPTextArguments {
    public static func strict(_ value: JsonValue?, parameter: String) throws -> [String: String] {
        guard let value, !value.isNull else { return [:] }
        guard let object = value.objectValue else {
            throw MCPProtocolError.invalidParams(detail: "\(parameter) must be an object of string values")
        }
        var arguments: [String: String] = [:]
        for (key, entry) in object {
            guard let text = text(entry) else {
                throw MCPProtocolError.invalidParams(detail: "\(parameter).\(key) must be a string")
            }
            arguments[key] = text
        }
        return arguments
    }

    public static func lenient(_ value: JsonValue?) -> [String: String] {
        guard let object = value?.objectValue else { return [:] }
        return object.compactMapValues(text)
    }

    public static func text(_ value: JsonValue) -> String? {
        switch value {
        case .string(let text):
            text
        case .int(let number):
            String(number)
        case .double(let number):
            String(number)
        case .bool(let flag):
            flag ? "true" : "false"
        case .null:
            ""
        case .array, .object:
            nil
        }
    }
}
