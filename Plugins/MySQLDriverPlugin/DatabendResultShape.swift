//
//  DatabendResultShape.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated internal enum DatabendResultShape {
    static let booleanTypeName = "BOOLEAN"

    private static let shortFieldType: UInt32 = 2
    private static let affectedRowsColumnPrefix = "number of rows "

    static func isBoolean(typeRaw: UInt32, length: UInt) -> Bool {
        typeRaw == shortFieldType && length == 1
    }

    static func booleanText(fromWireText text: String) -> String {
        switch text {
        case "1": return "true"
        case "0": return "false"
        default: return text
        }
    }

    static func binaryValue(fromWireText wire: Data) -> Data {
        guard wire.count.isMultiple(of: 2) else { return wire }
        var bytes = Data()
        bytes.reserveCapacity(wire.count / 2)
        var high: UInt8?
        for character in wire {
            guard let nibble = hexNibble(character) else { return wire }
            guard let pending = high else {
                high = nibble
                continue
            }
            bytes.append(pending << 4 | nibble)
            high = nil
        }
        return bytes
    }

    static func affectedRowCount(columns: [String], rows: [[PluginCellValue]]) -> UInt64? {
        guard columns.count == 1,
              columns[0].hasPrefix(affectedRowsColumnPrefix),
              rows.count == 1,
              let text = rows[0].first?.asText else { return nil }
        return UInt64(text)
    }

    private static func hexNibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
