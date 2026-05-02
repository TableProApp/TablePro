import Foundation

enum JsonValueLegacyBridge {
    static func toLegacy(_ value: JsonValue) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let bool):
            return .bool(bool)
        case .int(let int):
            return .int(int)
        case .double(let double):
            return .double(double)
        case .string(let string):
            return .string(string)
        case .array(let array):
            return .array(array.map { toLegacy($0) })
        case .object(let object):
            return .object(object.mapValues { toLegacy($0) })
        }
    }

    static func fromLegacy(_ value: JSONValue) -> JsonValue {
        switch value {
        case .null:
            return .null
        case .bool(let bool):
            return .bool(bool)
        case .int(let int):
            return .int(int)
        case .double(let double):
            return .double(double)
        case .string(let string):
            return .string(string)
        case .array(let array):
            return .array(array.map { fromLegacy($0) })
        case .object(let object):
            return .object(object.mapValues { fromLegacy($0) })
        }
    }
}

extension JsonValue {
    func toLegacy() -> JSONValue {
        JsonValueLegacyBridge.toLegacy(self)
    }

    static func fromLegacy(_ value: JSONValue) -> JsonValue {
        JsonValueLegacyBridge.fromLegacy(value)
    }
}
