//
//  LibPQCellDecoding.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum LibPQCellDecoding {
    private static let booleanOid: UInt32 = 16
    private static let byteaOid: UInt32 = 17

    static func value(from bytes: UnsafeRawBufferPointer, oid: UInt32) -> PluginCellValue {
        let text = text(from: bytes)
        switch oid {
        case byteaOid:
            guard let data = LibPQByteaDecoder.decode(text) else { return .text(text) }
            return .bytes(data)
        case booleanOid:
            return .text(text == "t" ? "true" : "false")
        default:
            return .text(text)
        }
    }

    static func text(from bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }
}
