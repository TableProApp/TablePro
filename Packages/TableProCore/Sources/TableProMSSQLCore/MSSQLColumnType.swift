import Foundation

public enum MSSQLColumnType: Sendable, Equatable {
    case char
    case varchar
    case text
    case nchar
    case nvarchar
    case ntext
    case tinyInt
    case smallInt
    case int
    case bigInt
    case float
    case real
    case decimal
    case money
    case smallMoney
    case bit
    case binary
    case varbinary
    case image
    case dateTime
    case smallDateTime
    case dateTimeN
    case date
    case time
    case dateTime2
    case dateTimeOffset
    case uniqueIdentifier
    case xml
    case sqlVariant
    case unknown(Int32)

    public var canonicalName: String {
        switch self {
        case .char: return "char"
        case .varchar: return "varchar"
        case .text: return "text"
        case .nchar: return "nchar"
        case .nvarchar: return "nvarchar"
        case .ntext: return "ntext"
        case .tinyInt: return "tinyint"
        case .smallInt: return "smallint"
        case .int: return "int"
        case .bigInt: return "bigint"
        case .float: return "float"
        case .real: return "real"
        case .decimal: return "decimal"
        case .money: return "money"
        case .smallMoney: return "smallmoney"
        case .bit: return "bit"
        case .binary: return "binary"
        case .varbinary: return "varbinary"
        case .image: return "image"
        case .dateTime, .dateTimeN: return "datetime"
        case .smallDateTime: return "smalldatetime"
        case .date: return "date"
        case .time: return "time"
        case .dateTime2: return "datetime2"
        case .dateTimeOffset: return "datetimeoffset"
        case .uniqueIdentifier: return "uniqueidentifier"
        case .xml: return "xml"
        case .sqlVariant: return "sql_variant"
        case .unknown: return "unknown"
        }
    }

    public var isDateOrTime: Bool {
        switch self {
        case .dateTime, .smallDateTime, .dateTimeN, .date, .time, .dateTime2, .dateTimeOffset:
            return true
        default:
            return false
        }
    }

    public var isBinary: Bool {
        switch self {
        case .binary, .varbinary, .image:
            return true
        default:
            return false
        }
    }

    public var isUnicodeString: Bool {
        switch self {
        case .nchar, .nvarchar, .ntext:
            return true
        default:
            return false
        }
    }

    public var isNarrowString: Bool {
        switch self {
        case .char, .varchar, .text:
            return true
        default:
            return false
        }
    }
}
