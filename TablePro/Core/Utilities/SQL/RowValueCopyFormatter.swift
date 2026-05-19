//
//  RowValueCopyFormatter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum RowValueCopyFormatter {
    static func copyText(cell: PluginCellValue, columnType: ColumnType?) -> String? {
        switch cell {
        case .null:
            return nil
        case .text(let value):
            if columnType?.isBlobType ?? false {
                return value.formattedAsCompactHex() ?? value
            }
            return value
        case .bytes(let data):
            return String(data: data, encoding: .isoLatin1)?.formattedAsCompactHex() ?? ""
        }
    }

    static func isIntegerLiteral(_ value: String) -> Bool {
        var iter = value.unicodeScalars.makeIterator()
        guard var first = iter.next() else { return false }
        if first == "-" {
            guard let next = iter.next() else { return false }
            first = next
        }
        guard first >= "0" && first <= "9" else { return false }
        while let next = iter.next() {
            guard next >= "0" && next <= "9" else { return false }
        }
        return true
    }
}
