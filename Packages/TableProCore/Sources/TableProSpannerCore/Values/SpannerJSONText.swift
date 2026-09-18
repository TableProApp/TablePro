import Foundation

internal enum SpannerJSONText {
    static func typed(_ value: SpannerJSONValue, type: SpannerType) -> String {
        var output = ""
        appendTyped(value, type: type, to: &output)
        return output
    }

    static func generic(_ value: SpannerJSONValue) -> String {
        var output = ""
        appendGeneric(value, to: &output)
        return output
    }

    static func floatText(_ number: Double, isFloat32: Bool) -> String {
        let single = Float(number)
        let text = isFloat32 && single.isFinite ? "\(single)" : "\(number)"
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func quoted(_ text: String) -> String {
        var output = ""
        appendQuoted(text, to: &output)
        return output
    }

    static func isNumberLiteral(_ text: String) -> Bool {
        var scalars = Array(text.utf8)[...]
        if scalars.first == UInt8(ascii: "-") {
            scalars = scalars.dropFirst()
        }
        guard let first = scalars.first, isDigit(first) else { return false }
        if first == UInt8(ascii: "0") {
            scalars = scalars.dropFirst()
        } else {
            scalars = scalars.drop(while: isDigit)
        }
        if scalars.first == UInt8(ascii: ".") {
            scalars = scalars.dropFirst()
            guard let digit = scalars.first, isDigit(digit) else { return false }
            scalars = scalars.drop(while: isDigit)
        }
        if scalars.first == UInt8(ascii: "e") || scalars.first == UInt8(ascii: "E") {
            scalars = scalars.dropFirst()
            if scalars.first == UInt8(ascii: "+") || scalars.first == UInt8(ascii: "-") {
                scalars = scalars.dropFirst()
            }
            guard let digit = scalars.first, isDigit(digit) else { return false }
            scalars = scalars.drop(while: isDigit)
        }
        return scalars.isEmpty
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func appendTyped(_ value: SpannerJSONValue, type: SpannerType, to output: inout String) {
        if case .null = value {
            output += "null"
            return
        }
        switch type.code {
        case SpannerTypeCode.array:
            appendArray(value, elementType: type.arrayElementType, to: &output)
        case SpannerTypeCode.structure:
            appendStruct(value, fields: type.structFields, to: &output)
        default:
            appendScalar(value, type: type, to: &output)
        }
    }

    private static func appendArray(_ value: SpannerJSONValue, elementType: SpannerType?, to output: inout String) {
        guard case .list(let elements) = value, let elementType else {
            appendGeneric(value, to: &output)
            return
        }
        output += "["
        for (position, element) in elements.enumerated() {
            if position > 0 {
                output += ","
            }
            appendTyped(element, type: elementType, to: &output)
        }
        output += "]"
    }

    private static func appendStruct(_ value: SpannerJSONValue, fields: [SpannerField], to output: inout String) {
        switch value {
        case .list(let members):
            let entries = members.enumerated().map { position, member in
                (key: memberName(fields, position), value: member, type: position < fields.count ? fields[position].type : nil)
            }
            appendObject(entries, to: &output)
        case .object(let members):
            let entries = fields.enumerated().compactMap { position, field -> (key: String, value: SpannerJSONValue, type: SpannerType?)? in
                guard let member = members[field.name] else { return nil }
                return (key: memberName(fields, position), value: member, type: field.type)
            }
            appendObject(entries, to: &output)
        default:
            appendGeneric(value, to: &output)
        }
    }

    private static func memberName(_ fields: [SpannerField], _ position: Int) -> String {
        guard position < fields.count, !fields[position].name.isEmpty else { return "_\(position)" }
        return fields[position].name
    }

    private static func appendObject(
        _ entries: [(key: String, value: SpannerJSONValue, type: SpannerType?)],
        to output: inout String
    ) {
        output += "{"
        for (position, entry) in entries.enumerated() {
            if position > 0 {
                output += ","
            }
            appendQuoted(entry.key, to: &output)
            output += ":"
            if let type = entry.type {
                appendTyped(entry.value, type: type, to: &output)
            } else {
                appendGeneric(entry.value, to: &output)
            }
        }
        output += "}"
    }

    private static func appendScalar(_ value: SpannerJSONValue, type: SpannerType, to output: inout String) {
        guard case .string(let text) = value else {
            appendGeneric(value, to: &output, isFloat32: type.code == SpannerTypeCode.float32)
            return
        }
        if SpannerTypeCode.isExactNumber(type.code), isNumberLiteral(text) {
            output += text
        } else if isJSONType(type), isValidJSON(text) {
            output += text
        } else {
            appendQuoted(text, to: &output)
        }
    }

    private static func isJSONType(_ type: SpannerType) -> Bool {
        type.code == SpannerTypeCode.json || type.typeAnnotation == SpannerTypeCode.pgJSONBAnnotation
    }

    private static func isValidJSON(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil
    }

    private static func appendGeneric(_ value: SpannerJSONValue, to output: inout String, isFloat32: Bool = false) {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .number(let number):
            output += number.isFinite ? floatText(number, isFloat32: isFloat32) : "null"
        case .string(let text):
            appendQuoted(text, to: &output)
        case .list(let elements):
            output += "["
            for (position, element) in elements.enumerated() {
                if position > 0 {
                    output += ","
                }
                appendGeneric(element, to: &output)
            }
            output += "]"
        case .object(let members):
            let entries = members.keys.sorted().compactMap { key -> (key: String, value: SpannerJSONValue, type: SpannerType?)? in
                members[key].map { (key: key, value: $0, type: nil) }
            }
            appendObject(entries, to: &output)
        }
    }

    private static func appendQuoted(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
