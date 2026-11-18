//
//  LibPQCellDecoding.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

nonisolated internal enum LibPQCellDecoding {
    private static let booleanOid: UInt32 = 16
    private static let byteaOid: UInt32 = 17

    static func value(from bytes: UnsafeRawBufferPointer, oid: UInt32) -> PluginCellValue {
        switch oid {
        case byteaOid:
            guard let data = LibPQByteaDecoder.decode(bytes: bytes) else { return .text(text(from: bytes)) }
            return .bytes(data)
        case booleanOid:
            return .text(text(from: bytes) == "t" ? "true" : "false")
        default:
            return .text(text(from: bytes))
        }
    }

    static func text(from bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }
}
