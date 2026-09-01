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
        case .binary(let data): "\"\(hex(data, limit: maxDisplayedHexBytes))\""
        }
    }

    /// The value without its quotes, which is what Copy Value puts on the pasteboard.
    ///
    /// A blob prints in full here even though the line on screen stops at
    /// `maxDisplayedHexBytes`: what the pasteboard carries is the value, not the rendering of it.
    static func unquoted(_ scalar: JSONScalar) -> String {
        switch scalar {
        case .string(let text): text
        case .number(let literal): literal
        case .bool(let flag): flag ? "true" : "false"
        case .null: "NULL"
        case .binary(let data): hex(data, limit: nil)
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

    /// How much of a blob a printed line carries. A column holding a megabyte of image data is not
    /// a value anyone reads byte by byte, and laying the whole of it out as one line costs more
    /// than the reader gets back.
    static let maxDisplayedHexBytes = 64

    private static let hexDigits = Array("0123456789ABCDEF")

    private static func hex(_ data: Data, limit: Int?) -> String {
        let shown = limit.map { data.prefix($0) } ?? data[...]
        var output = "0x"
        output.reserveCapacity(shown.count * 2 + 3)
        for byte in shown {
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0F)])
        }
        if let limit, data.count > limit { output.append("…") }
        return output
    }
}
