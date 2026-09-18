import Foundation

public enum SpannerParameterEncodingError: Error, Sendable, Equatable {
    case notBoolean(index: Int)
    case notNumber(index: Int)
    case notJSONArray(index: Int)
    case unsupportedType(String)
}

public enum SpannerParameterEncoder {
    private static let specialFloats: [String: String] = [
        "nan": "NaN",
        "infinity": "Infinity",
        "+infinity": "Infinity",
        "inf": "Infinity",
        "+inf": "Infinity",
        "-infinity": "-Infinity",
        "-inf": "-Infinity"
    ]

    public static func encode(_ value: SpannerCell, as type: SpannerType, index: Int) throws -> SpannerJSONValue {
        switch value {
        case .null:
            return .null
        case .bytes(let data):
            return try encodeBytes(data, as: type, index: index)
        case .text(let text):
            return try encodeText(text, as: type, index: index)
        }
    }

    private static func encodeBytes(_ data: Data, as type: SpannerType, index: Int) throws -> SpannerJSONValue {
        if type.code == SpannerTypeCode.bytes {
            return .string(data.base64EncodedString())
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SpannerParameterEncodingError.unsupportedType(SpannerValueDecoder.displayTypeName(type))
        }
        return try encodeText(text, as: type, index: index)
    }

    private static func encodeText(_ text: String, as type: SpannerType, index: Int) throws -> SpannerJSONValue {
        switch type.code {
        case SpannerTypeCode.bool:
            return .bool(try boolean(text, index: index))
        case SpannerTypeCode.float64, SpannerTypeCode.float32:
            return try float(text, index: index)
        case SpannerTypeCode.array:
            return try array(text, elementType: type.arrayElementType, index: index)
        case SpannerTypeCode.structure:
            throw SpannerParameterEncodingError.unsupportedType(SpannerValueDecoder.displayTypeName(type))
        default:
            return .string(text)
        }
    }

    private static func boolean(_ text: String, index: Int) throws -> Bool {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            throw SpannerParameterEncodingError.notBoolean(index: index)
        }
    }

    private static func float(_ text: String, index: Int) throws -> SpannerJSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let special = specialFloats[trimmed.lowercased()] {
            return .string(special)
        }
        guard let number = Double(trimmed), number.isFinite else {
            throw SpannerParameterEncodingError.notNumber(index: index)
        }
        return .number(number)
    }

    private static func array(_ text: String, elementType: SpannerType?, index: Int) throws -> SpannerJSONValue {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: []),
              let elements = object as? [Any]
        else {
            throw SpannerParameterEncodingError.notJSONArray(index: index)
        }
        guard let elementType else {
            throw SpannerParameterEncodingError.unsupportedType(SpannerTypeCode.array)
        }
        return .list(try elements.map { try element($0, as: elementType, index: index) })
    }

    private static func element(_ element: Any, as type: SpannerType, index: Int) throws -> SpannerJSONValue {
        if element is NSNull {
            return .null
        }
        switch type.code {
        case SpannerTypeCode.array, SpannerTypeCode.structure:
            throw SpannerParameterEncodingError.unsupportedType(SpannerValueDecoder.displayTypeName(type))
        case SpannerTypeCode.bool:
            return try booleanElement(element, index: index)
        case SpannerTypeCode.float64, SpannerTypeCode.float32:
            return try floatElement(element, index: index)
        case SpannerTypeCode.json:
            return try jsonElement(element, index: index)
        default:
            return try scalarElement(element, index: index)
        }
    }

    private static func booleanElement(_ element: Any, index: Int) throws -> SpannerJSONValue {
        if let number = element as? NSNumber {
            guard isBoolean(number) else { return .bool(try boolean(number.stringValue, index: index)) }
            return .bool(number.boolValue)
        }
        guard let text = element as? String else { throw SpannerParameterEncodingError.notBoolean(index: index) }
        return .bool(try boolean(text, index: index))
    }

    private static func floatElement(_ element: Any, index: Int) throws -> SpannerJSONValue {
        if let number = element as? NSNumber, !isBoolean(number) {
            guard number.doubleValue.isFinite else { throw SpannerParameterEncodingError.notNumber(index: index) }
            return .number(number.doubleValue)
        }
        guard let text = element as? String else { throw SpannerParameterEncodingError.notNumber(index: index) }
        return try float(text, index: index)
    }

    private static func jsonElement(_ element: Any, index: Int) throws -> SpannerJSONValue {
        if let text = element as? String {
            return .string(text)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: element,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            throw SpannerParameterEncodingError.notJSONArray(index: index)
        }
        return .string(text)
    }

    private static func scalarElement(_ element: Any, index: Int) throws -> SpannerJSONValue {
        if let text = element as? String {
            return .string(text)
        }
        guard let number = element as? NSNumber else {
            throw SpannerParameterEncodingError.notJSONArray(index: index)
        }
        return isBoolean(number) ? .bool(number.boolValue) : .string(number.stringValue)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
