//
//  PhpSerializeWriter.swift
//  TablePro
//

import Foundation

// Writes what PHP's serialize() writes, so the decoded text reads back in the PHP Serialized viewer.
internal enum PhpSerializeWriter {
    static func text(_ value: PhpValue, limit: Int = .max) -> String {
        var output = ""
        write(value, into: &output, limit: limit)
        return output
    }

    private static func write(_ value: PhpValue, into output: inout String, limit: Int) {
        guard output.utf8.count < limit else { return }
        switch value {
        case .null:
            output += "N;"
        case .bool(let flag):
            output += flag ? "b:1;" : "b:0;"
        case .int(let number):
            output += "i:\(number);"
        case .float(let number):
            output += "d:\(floatText(number));"
        case .string(let text):
            output += quoted("s", text) + ";"
        case .array(let entries):
            output += "a:\(entries.count):{"
            for entry in entries {
                guard output.utf8.count < limit else { return }
                write(entry.key, into: &output, limit: limit)
                write(entry.value, into: &output, limit: limit)
            }
            output += "}"
        case .object(let className, let properties):
            output += quoted("O", className) + ":\(properties.count):{"
            for property in properties {
                guard output.utf8.count < limit else { return }
                output += quoted("s", mangled(property)) + ";"
                write(property.value, into: &output, limit: limit)
            }
            output += "}"
        case .serializable(let className, let rawPayload):
            output += quoted("C", className) + ":\(rawPayload.utf8.count):{\(rawPayload)}"
        case .enumCase(let className, let caseName):
            output += quoted("E", "\(className):\(caseName)") + ";"
        case .reference(let id):
            output += "R:\(id);"
        case .unsupported(let token):
            output += token
        case .depthExceeded, .tooLarge:
            output += "…"
        }
    }

    private static func quoted(_ token: String, _ text: String) -> String {
        "\(token):\(text.utf8.count):\"\(text)\""
    }

    private static func mangled(_ property: PhpProperty) -> String {
        switch property.visibility {
        case .publicVisibility: return property.name
        case .protectedVisibility: return "\u{0}*\u{0}\(property.name)"
        case .privateVisibility(let className): return "\u{0}\(className)\u{0}\(property.name)"
        }
    }

    // serialize_precision -1: the shortest text that reads back, `1.0E+25` past 15 digits.
    static func floatText(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value > 0 ? "INF" : "-INF" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let text = "\(value)"
        guard let exponentIndex = text.firstIndex(of: "e") else { return text }
        var mantissa = String(text[..<exponentIndex])
        if !mantissa.contains(".") { mantissa += ".0" }
        let exponent = Int(text[text.index(after: exponentIndex)...]) ?? 0
        return mantissa + "E" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
    }
}
