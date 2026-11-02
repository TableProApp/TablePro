//
//  BinaryValueBytes.swift
//  TablePro
//

import Foundation

internal enum BinaryValueBytes {
    // Bytes reach a String one Latin-1 character per byte; a text column's value is its own UTF-8.
    static func data(of text: String, holdsBytes: Bool) -> Data? {
        holdsBytes ? text.data(using: .isoLatin1) : Data(text.utf8)
    }

    static func holdsBytes(columnType: ColumnType?, isBinaryValue: Bool = false) -> Bool {
        isBinaryValue || columnType?.isBlobType != false
    }
}
