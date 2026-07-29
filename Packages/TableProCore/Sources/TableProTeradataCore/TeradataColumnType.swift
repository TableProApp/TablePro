import Foundation

public enum TeradataTypeCategory: Sendable {
    case numeric
    case text
    case temporal
    case binary
    case interval
    case largeObject
    case other
}

public enum TeradataColumnType {
    public static func displayName(
        dbcColumnType: String, length: Int, totalDigits: Int, fractionalDigits: Int
    ) -> String {
        let code = dbcColumnType.trimmingCharacters(in: .whitespaces).uppercased()
        switch code {
        case "I1": return "BYTEINT"
        case "I2": return "SMALLINT"
        case "I": return "INTEGER"
        case "I8": return "BIGINT"
        case "F": return "FLOAT"
        case "D": return "DECIMAL(\(totalDigits),\(fractionalDigits))"
        case "N": return totalDigits > 0 ? "NUMBER(\(totalDigits),\(fractionalDigits))" : "NUMBER"
        case "DA": return "DATE"
        case "AT": return "TIME"
        case "TS": return "TIMESTAMP"
        case "TZ": return "TIME WITH TIME ZONE"
        case "SZ": return "TIMESTAMP WITH TIME ZONE"
        case "CF": return "CHAR(\(length))"
        case "CV": return "VARCHAR(\(length))"
        case "CO": return "CLOB"
        case "BF": return "BYTE(\(length))"
        case "BV": return "VARBYTE(\(length))"
        case "BO": return "BLOB"
        case "JN": return "JSON"
        case "XM": return "XML"
        case "UT": return "UDT"
        case "PD": return "PERIOD(DATE)"
        case "PT": return "PERIOD(TIME)"
        case "PS": return "PERIOD(TIMESTAMP)"
        case "YR": return "INTERVAL YEAR"
        case "YM": return "INTERVAL YEAR TO MONTH"
        case "MO": return "INTERVAL MONTH"
        case "DY": return "INTERVAL DAY"
        case "DH": return "INTERVAL DAY TO HOUR"
        case "DM": return "INTERVAL DAY TO MINUTE"
        case "DS": return "INTERVAL DAY TO SECOND"
        case "HR": return "INTERVAL HOUR"
        case "HM": return "INTERVAL HOUR TO MINUTE"
        case "HS": return "INTERVAL HOUR TO SECOND"
        case "MI": return "INTERVAL MINUTE"
        case "MS": return "INTERVAL MINUTE TO SECOND"
        case "SC": return "INTERVAL SECOND"
        default: return code.isEmpty ? "UNKNOWN" : code
        }
    }

    public static func wireTypeName(_ code: UInt16) -> String {
        switch code & 0xFFFE {
        case TeradataType.byteint: return "BYTEINT"
        case TeradataType.smallint: return "SMALLINT"
        case TeradataType.integer: return "INTEGER"
        case TeradataType.bigint: return "BIGINT"
        case TeradataType.float: return "FLOAT"
        case TeradataType.decimal: return "DECIMAL"
        case 604: return "NUMBER"
        case TeradataType.char: return "CHAR"
        case TeradataType.varchar: return "VARCHAR"
        case TeradataType.longVarchar: return "LONG VARCHAR"
        case TeradataType.byte: return "BYTE"
        case TeradataType.varbyte: return "VARBYTE"
        case TeradataType.dateInteger, TeradataType.dateAnsi: return "DATE"
        case 760: return "TIME"
        case 764: return "TIMESTAMP"
        case 768: return "TIME WITH TIME ZONE"
        case 772: return "TIMESTAMP WITH TIME ZONE"
        case 400: return "BLOB"
        case 416: return "CLOB"
        case 880: return "JSON"
        default: return "VARCHAR"
        }
    }

    public static func category(wireTypeCode: UInt16) -> TeradataTypeCategory {
        switch wireTypeCode & 0xFFFE {
        case TeradataType.integer, TeradataType.smallint, TeradataType.bigint,
             TeradataType.byteint, TeradataType.float, TeradataType.decimal, 604:
            return .numeric
        case TeradataType.char, TeradataType.varchar, TeradataType.longVarchar:
            return .text
        case TeradataType.dateInteger, TeradataType.dateAnsi, 760, 764, 768, 772:
            return .temporal
        case TeradataType.byte, TeradataType.varbyte:
            return .binary
        case 400, 416, 880, 852:
            return .largeObject
        case 776, 780, 784, 788, 792, 796, 800, 804, 808, 812, 816, 820, 824:
            return .interval
        default:
            return .other
        }
    }
}
