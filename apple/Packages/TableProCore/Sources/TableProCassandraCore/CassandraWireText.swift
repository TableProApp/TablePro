//
//  CassandraWireText.swift
//  TableProCassandraCore
//

import Foundation

public enum CassandraWireText {
    // Foundation's UTF-8 initializers drop a leading byte order mark, and a key that starts with one names another row.
    public static func text(_ bytes: UnsafeRawBufferPointer) -> String? {
        let text = String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return text.utf8.elementsEqual(bytes) ? text : nil
    }

    public static func text(_ bytes: Data) -> String? {
        let text = String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return text.utf8.elementsEqual(bytes) ? text : nil
    }
}
