//
//  JSONScalarText.swift
//  TablePro
//
//  How a scalar prints in the JSON inspector, shared by the view and by Copy Visible.
//

import Foundation

enum JSONScalarText {
    /// The value as it is printed, quotes included, so the view and the clipboard cannot disagree.
    static func printed(_ scalar: JSONScalar) -> String {
        switch scalar {
        case .string(let text): "\"\(escaped(text))\""
        case .number(let literal): literal
        case .bool(let flag): flag ? "true" : "false"
        case .null: "null"
        case .binary(let data): hex(data)
        }
    }

    /// The value without its quotes, which is what Copy Value puts on the pasteboard.
    static func unquoted(_ scalar: JSONScalar) -> String {
        switch scalar {
        case .string(let text): text
        case .number(let literal): literal
        case .bool(let flag): flag ? "true" : "false"
        case .null: "NULL"
        case .binary(let data): hex(data)
        }
    }

    static func escaped(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count + 2)
        for character in text.unicodeScalars {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if character.value < 0x20 {
                    output += String(format: "\\u%04x", character.value)
                } else {
                    output.unicodeScalars.append(character)
                }
            }
        }
        return output
    }

    private static func hex(_ data: Data) -> String {
        let latin1 = String(data: data, encoding: .isoLatin1) ?? ""
        guard let formatted = latin1.formattedAsCompactHex() else { return "\"\"" }
        return "\"\(formatted)\""
    }
}
