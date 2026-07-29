import Foundation

struct ColumnMeta {
    let typeCode: UInt16
    let dataLength: Int
    let name: String

    var isNullable: Bool { typeCode & 1 == 1 }
    var baseCode: UInt16 { typeCode & 0xFFFE }
}

public enum TeradataValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case bytes([UInt8])
}

enum TeradataType {
    static let integer: UInt16 = 496
    static let smallint: UInt16 = 500
    static let bigint: UInt16 = 600
    static let byteint: UInt16 = 756
    static let float: UInt16 = 480
    static let decimal: UInt16 = 484
    static let char: UInt16 = 452
    static let varchar: UInt16 = 448
    static let longVarchar: UInt16 = 456
    static let byte: UInt16 = 692
    static let varbyte: UInt16 = 688
    static let dateInteger: UInt16 = 752
    static let dateAnsi: UInt16 = 748

    static func signedInteger(_ bytes: [UInt8]) -> Int64 {
        var value: Int64 = (bytes.first ?? 0) & 0x80 != 0 ? -1 : 0
        for byte in bytes { value = (value << 8) | Int64(byte) }
        return value
    }
}
