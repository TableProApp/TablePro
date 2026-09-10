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
    /// A blob is capped here as well, at the same 64 bytes `RowValueCopyFormatter` gives the grid's
    /// own Copy: one cell copied two ways cannot come back as two different values. Carrying the
    /// whole blob instead would also mean hex-encoding an unbounded value on the main actor while
    /// the reader waits for the pasteboard. The quotes are what was wrong, not the cap.
    static func unquoted(_ scalar: JSONScalar) -> String {
        switch scalar {
        case .string(let text): text
        case .number(let literal): literal
        case .bool(let flag): flag ? "true" : "false"
        case .null: "NULL"
        case .binary(let data): hex(data, limit: maxDisplayedHexBytes)
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

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Written into a byte buffer and decoded once rather than appended a character at a time.
    /// Copy Value asks for the whole blob, so this runs over every byte of a value that can be
    /// megabytes, on the main thread, while the reader waits for the pasteboard.
    private static func hex(_ data: Data, limit: Int?) -> String {
        let shown = limit.map { data.prefix($0) } ?? data[...]
        var bytes: [UInt8] = [0x30, 0x78]
        bytes.reserveCapacity(shown.count * 2 + 5)
        for byte in shown {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0F)])
        }
        var output = String(unsafeUninitializedCapacity: bytes.count) { buffer in
            _ = buffer.initialize(from: bytes)
            return bytes.count
        }
        if let limit, data.count > limit { output.append("…") }
        return output
    }
}
