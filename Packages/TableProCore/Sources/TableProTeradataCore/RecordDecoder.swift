import Foundation

enum RecordDecoder {
    static func nullBitmapLength(columnCount: Int) -> Int {
        (columnCount + 7) / 8
    }

    static func isNull(_ bitmap: [UInt8], column: Int) -> Bool {
        let byteIndex = column / 8
        guard byteIndex < bitmap.count else { return false }
        return bitmap[byteIndex] & (0x80 >> UInt8(column % 8)) != 0
    }

    static func decode(recordBody: [UInt8], columns: [ColumnMeta]) throws -> [TeradataValue] {
        var reader = ByteReader(recordBody)
        let bitmap = try reader.take(nullBitmapLength(columnCount: columns.count))
        var values: [TeradataValue] = []
        values.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            let raw = try readFieldBytes(&reader, column: column)
            if isNull(bitmap, column: index) {
                values.append(.null)
            } else {
                values.append(try interpret(raw, column: column))
            }
        }
        return values
    }

    private static func readFieldBytes(_ reader: inout ByteReader, column: ColumnMeta) throws -> [UInt8] {
        switch column.baseCode {
        case TeradataType.byteint: return try reader.take(1)
        case TeradataType.smallint: return try reader.take(2)
        case TeradataType.integer, TeradataType.dateInteger: return try reader.take(4)
        case TeradataType.bigint, TeradataType.float: return try reader.take(8)
        case TeradataType.char, TeradataType.byte: return try reader.take(column.dataLength)
        case TeradataType.varchar, TeradataType.longVarchar, TeradataType.varbyte:
            let length = Int(try reader.u16())
            return try reader.take(length)
        case TeradataType.decimal:
            return try reader.take(decimalByteWidth(precision: column.dataLength >> 8))
        default:
            throw TeradataWireError.unsupported("record field type \(column.baseCode)")
        }
    }

    static func decimalByteWidth(precision: Int) -> Int {
        switch precision {
        case ...2: return 1
        case 3...4: return 2
        case 5...9: return 4
        case 10...18: return 8
        default: return 16
        }
    }

    static func decimalString(_ bytes: [UInt8], scale: Int) -> String {
        let negative = (bytes.first ?? 0) & 0x80 != 0
        var magnitude = bytes
        if negative {
            var carry = 1
            for index in stride(from: magnitude.count - 1, through: 0, by: -1) {
                let value = Int(~magnitude[index] & 0xFF) + carry
                magnitude[index] = UInt8(value & 0xFF)
                carry = value >> 8
            }
        }
        var digits = base256ToDecimal(magnitude)
        if scale > 0 {
            while digits.count <= scale { digits = "0" + digits }
            let dot = digits.index(digits.endIndex, offsetBy: -scale)
            digits = digits[..<dot] + "." + digits[dot...]
        }
        return (negative ? "-" : "") + digits
    }

    private static func base256ToDecimal(_ bytes: [UInt8]) -> String {
        var value = bytes
        var result = ""
        while value.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in value.indices {
                let accumulator = remainder * 256 + Int(value[index])
                value[index] = UInt8(accumulator / 10)
                remainder = accumulator % 10
            }
            result = String(remainder) + result
        }
        return result.isEmpty ? "0" : result
    }

    private static func interpret(_ bytes: [UInt8], column: ColumnMeta) throws -> TeradataValue {
        switch column.baseCode {
        case TeradataType.byteint, TeradataType.smallint, TeradataType.integer, TeradataType.bigint:
            return .integer(TeradataType.signedInteger(bytes))
        case TeradataType.float:
            var pattern: UInt64 = 0
            for byte in bytes { pattern = (pattern << 8) | UInt64(byte) }
            return .double(Double(bitPattern: pattern))
        case TeradataType.char, TeradataType.varchar, TeradataType.longVarchar:
            let text = String(decoding: bytes, as: UTF8.self)
            return .text(column.baseCode == TeradataType.char
                ? String(text.reversed().drop { $0 == " " }.reversed())
                : text)
        case TeradataType.decimal:
            return .text(decimalString(bytes, scale: column.dataLength & 0xFF))
        case TeradataType.byte, TeradataType.varbyte:
            return .bytes(bytes)
        case TeradataType.dateInteger:
            let packed = TeradataType.signedInteger(bytes)
            let year = 1900 + Int(packed / 10000)
            let month = Int((packed / 100) % 100)
            let day = Int(packed % 100)
            return .text(String(format: "%04d-%02d-%02d", year, month, day))
        default:
            throw TeradataWireError.unsupported("record field type \(column.baseCode)")
        }
    }
}
