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

    // Text past `limit` is cut before it is copied, so a large string costs what the preview shows of it. The lengths
    // stay the full ones, and the caller marks the cut.
    private static func write(_ value: PhpValue, into output: inout String, limit: Int) {
        let room = limit - output.utf8.count
        guard room > 0 else { return }
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
            output += quoted("s", text, room: room) + ";"
        case .binaryString(let bytes):
            // The length is the byte count serialize() writes; the bytes show one character each.
            output += "s:\(bytes.count):\"\(latin1(bytes.prefix(room)))\";"
        case .array(let entries):
            output += "a:\(entries.count):{"
            for entry in entries {
                guard output.utf8.count < limit else { return }
                write(entry.key, into: &output, limit: limit)
                write(entry.value, into: &output, limit: limit)
            }
            output += "}"
        case .object(let className, let properties):
            output += quoted("O", className, room: room) + ":\(properties.count):{"
            for property in properties {
                guard output.utf8.count < limit else { return }
                if let index = property.index {
                    output += "i:\(index);"
                } else if let binaryKey = property.binaryKey {
                    output += "s:\(binaryKey.count):\"\(latin1(binaryKey.prefix(limit - output.utf8.count)))\";"
                } else {
                    output += quoted("s", mangled(property), room: limit - output.utf8.count) + ";"
                }
                write(property.value, into: &output, limit: limit)
            }
            output += "}"
        case .serializable(let className, let rawPayload):
            output += quoted("C", className, room: room) + ":\(rawPayload.utf8.count):{\(rawPayload.scalarPrefix(room))}"
        case .binarySerializable(let className, let payload):
            output += quoted("C", className, room: room) + ":\(payload.count):{\(latin1(payload.prefix(room)))}"
        case .enumCase(let className, let caseName):
            output += quoted("E", "\(className):\(caseName)", room: room) + ";"
        case .reference(let id):
            output += "R:\(id);"
        case .objectReference(let id):
            output += "r:\(id);"
        case .unsupported(let token):
            output += token
        case .depthExceeded, .tooLarge:
            output += "…"
        }
    }

    private static func quoted(_ token: String, _ text: String, room: Int) -> String {
        "\(token):\(text.utf8.count):\"\(text.scalarPrefix(room))\""
    }

    private static func latin1(_ bytes: Data) -> String {
        String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func mangled(_ property: PhpProperty) -> String {
        switch property.visibility {
        case .publicVisibility: return property.name
        case .protectedVisibility: return "\u{0}*\u{0}\(property.name)"
        case .privateVisibility(let className): return "\u{0}\(className)\u{0}\(property.name)"
        }
    }

    // php_gcvt with serialize_precision -1: the shortest digits that read back, in E notation only when the
    // decimal point falls more than 17 digits right or 4 digits left of the first digit.
    static func floatText(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value < 0 ? "-INF" : "INF" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }

        let (digits, point) = shortestDigits(abs(value))
        if point < -3 || point > 17 {
            let mantissa = digits.count == 1 ? digits + ".0" : "\(digits.prefix(1)).\(digits.dropFirst())"
            let exponent = point - 1
            return sign + mantissa + "E" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        }
        if point <= 0 {
            return sign + "0." + String(repeating: "0", count: -point) + digits
        }
        if digits.count <= point {
            return sign + digits + String(repeating: "0", count: point - digits.count)
        }
        return sign + digits.prefix(point) + "." + digits.dropFirst(point)
    }

    // Swift's description is the shortest round-trip text too; this reads the digits and the decimal point's
    // position off it, as dtoa mode 0 returns them.
    private static func shortestDigits(_ value: Double) -> (digits: String, point: Int) {
        var text = "\(value)"
        var exponent = 0
        if let marker = text.firstIndex(of: "e") {
            exponent = Int(text[text.index(after: marker)...]) ?? 0
            text = String(text[..<marker])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Substring(parts[0] + (parts.count > 1 ? parts[1] : ""))
        var point = parts[0].count + exponent
        while digits.first == "0" {
            digits = digits.dropFirst()
            point -= 1
        }
        while digits.last == "0" {
            digits = digits.dropLast()
        }
        return (String(digits), point)
    }
}
