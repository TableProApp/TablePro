//
//  PhpSerializeWriter.swift
//  TablePro
//

import Foundation

internal enum PhpSerializeWriter {
    static func serialize(_ value: PhpValue, limit: Int = .max) -> String {
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
            writeString(text, into: &output, limit: limit)
        case .bytes(let bytes):
            let shown = escaped(bytes.prefix(Swift.max(0, limit - output.utf8.count)))
            output += "s:\(bytes.count):\"\(shown)\";"
        case .array(let entries):
            output += "a:\(entries.count):{"
            for entry in entries {
                write(entry.key, into: &output, limit: limit)
                write(entry.value, into: &output, limit: limit)
            }
            output += "}"
        case .object(let className, let properties):
            output += "O:\(className.utf8.count):\"\(className)\":\(properties.count):{"
            for property in properties {
                writeString(mangledName(property), into: &output, limit: limit)
                write(property.value, into: &output, limit: limit)
            }
            output += "}"
        case .serializable(let className, let rawPayload):
            let shown = rawPayload.scalarPrefix(limit - output.utf8.count)
            output += "C:\(className.utf8.count):\"\(className)\":\(rawPayload.utf8.count):{\(shown)}"
        case .enumCase(let className, let caseName):
            let name = "\(className):\(caseName)"
            output += "E:\(name.utf8.count):\"\(name)\";"
        case .reference(let id):
            output += "r:\(id);"
        case .variableReference(let id):
            output += "R:\(id);"
        case .unsupported(let token):
            output += token
        case .depthExceeded, .tooLarge:
            output += "…"
        }
    }

    // Bytes as a PHP double-quoted literal spells them, so `s:1:"\xFF";` keeps its true length.
    static func escaped(_ bytes: Data) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\\"):
                output += [byte, byte]
            case 0x20...0x7E:
                output.append(byte)
            default:
                output += [UInt8(ascii: "\\"), UInt8(ascii: "x"), digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
            }
        }
        return String(bytes: output, encoding: .ascii) ?? ""
    }

    private static func writeString(_ text: String, into output: inout String, limit: Int) {
        let shown = text.scalarPrefix(limit - output.utf8.count)
        output += "s:\(text.utf8.count):\"\(shown)\";"
    }

    private static func mangledName(_ property: PhpProperty) -> String {
        switch property.visibility {
        case .publicVisibility: return property.name
        case .protectedVisibility: return "\u{0}*\u{0}\(property.name)"
        case .privateVisibility(let className): return "\u{0}\(className)\u{0}\(property.name)"
        }
    }

    // serialize() with serialize_precision -1: no `.0` on a whole number, `1.0E+100` for an exponent.
    static func floatText(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value > 0 ? "INF" : "-INF" }
        let description = value.description
        guard let exponentIndex = description.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            return description.hasSuffix(".0") ? String(description.dropLast(2)) : description
        }
        var mantissa = String(description[..<exponentIndex])
        if !mantissa.contains(".") { mantissa += ".0" }
        var exponent = String(description[description.index(after: exponentIndex)...])
        let sign = exponent.hasPrefix("-") ? "-" : "+"
        exponent = String(exponent.drop { $0 == "+" || $0 == "-" || $0 == "0" })
        return "\(mantissa)E\(sign)\(exponent.isEmpty ? "0" : exponent)"
    }
}
