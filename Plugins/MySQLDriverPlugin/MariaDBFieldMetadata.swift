//
//  MariaDBFieldMetadata.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal let mysqlNotNullFlag: UInt = 0x0001
internal let mysqlPriKeyFlag: UInt = 0x0002
internal let mysqlBinaryFlag: UInt = 0x0080
internal let mysqlEnumFlag: UInt = 0x0100
internal let mysqlAutoIncrementFlag: UInt = 0x0200
internal let mysqlSetFlag: UInt = 0x0800
internal let mysqlBinaryCharset: UInt32 = 63

internal func makeColumnMeta(name: String, typeName: String, flags: UInt) -> PluginColumnInfo {
    PluginColumnInfo(
        name: name,
        dataType: typeName,
        isNullable: (flags & mysqlNotNullFlag) == 0,
        isPrimaryKey: (flags & mysqlPriKeyFlag) != 0,
        identityKind: (flags & mysqlAutoIncrementFlag) != 0 ? .byDefault : nil
    )
}

internal func mariaDBTypeName(
    typeRaw: UInt32,
    flags: UInt,
    charsetnr: UInt32,
    length: UInt
) -> String {
    let isBinary = (flags & mysqlBinaryFlag) != 0 && charsetnr == mysqlBinaryCharset

    switch typeRaw {
    case 0: return "DECIMAL"
    case 1: return "TINYINT"
    case 2: return "SMALLINT"
    case 3: return "INT"
    case 4: return "FLOAT"
    case 5: return "DOUBLE"
    case 6: return "NULL"
    case 7: return "TIMESTAMP"
    case 8: return "BIGINT"
    case 9: return "MEDIUMINT"
    case 10: return "DATE"
    case 11: return "TIME"
    case 12: return "DATETIME"
    case 13: return "YEAR"
    case 14: return "NEWDATE"
    case 15: return "VARCHAR"
    case 16: return "BIT"
    case 245: return "JSON"
    case 246: return "NEWDECIMAL"
    case 247: return "ENUM"
    case 248: return "SET"
    case 249:
        return isBinary ? "TINYBLOB" : "TINYTEXT"
    case 250:
        return isBinary ? "MEDIUMBLOB" : "MEDIUMTEXT"
    case 251:
        return isBinary ? "LONGBLOB" : "LONGTEXT"
    case 252:
        if isBinary {
            return length > 65_535 ? "LONGBLOB" : "BLOB"
        } else {
            return length > 65_535 ? "LONGTEXT" : "TEXT"
        }
    case 253: return isBinary ? "VARBINARY" : "VARCHAR"
    case 254: return isBinary ? "BINARY" : "CHAR"
    case 255: return "GEOMETRY"
    default: return "UNKNOWN"
    }
}
