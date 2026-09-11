import CMariaDB
import Foundation
import OSLog

nonisolated internal enum MariaDBCharacterSet {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MariaDBCharacterSet")

    static func establishSession(on mysql: UnsafeMutablePointer<MYSQL>, encoding: MySQLConnectionEncoding) -> Bool {
        if mysql_set_character_set(mysql, MySQLConnectionEncoding.sessionCharacterSetName) != 0 {
            let refusal = errorSummary(of: mysql, encoding: encoding)
            if run(MySQLConnectionEncoding.sessionFallbackStatement, on: mysql) {
                logger.notice("Server refused utf8mb4 (\(refusal, privacy: .public)), so the session uses utf8")
            } else {
                logger.warning("Server refused a UTF-8 session (\(refusal, privacy: .public)); keeping its own")
            }
        }
        for statement in encoding.sessionStatements where !run(statement, on: mysql) {
            return false
        }
        return true
    }

    static func name(forCollation collation: UInt32) -> String? {
        guard let info = mariadb_get_charset_by_nr(collation), let name = info.pointee.csname else { return nil }
        return String(cString: name)
    }

    static func describeColumns(
        of fields: UnsafeMutablePointer<MYSQL_FIELD>?,
        count: Int,
        encoding: MySQLConnectionEncoding,
        flavor: MySQLServerFlavor = .mysql
    ) -> MySQLResultColumns {
        var columns = MySQLResultColumns()
        guard let fields else { return columns }
        for index in 0..<count {
            let field = fields[index]
            let flags = UInt(field.flags)
            let decoding = MySQLColumnDecoding(
                typeRaw: field.type.rawValue,
                length: field.length,
                charsetnr: field.charsetnr,
                characterSetName: name(forCollation: field.charsetnr),
                flavor: flavor
            )
            columns.append(
                name: decodedName(of: field, encoding: encoding) ?? "column_\(index)",
                typeCode: typeCode(of: field, flags: flags),
                typeName: typeName(of: fields + index, decoding: decoding),
                decoding: decoding,
                flags: flags
            )
        }
        return columns
    }

    private static func typeName(
        of field: UnsafePointer<MYSQL_FIELD>,
        decoding: MySQLColumnDecoding
    ) -> String {
        guard decoding != .databendBoolean else { return DatabendResultShape.booleanTypeName }
        return mysqlTypeToString(field)
    }

    private static func typeCode(of field: MYSQL_FIELD, flags: UInt) -> UInt32 {
        if (flags & mysqlSetFlag) != 0 { return 248 }
        if (flags & mysqlEnumFlag) != 0 { return 247 }
        return field.type.rawValue
    }

    static func decodedName(of field: MYSQL_FIELD, encoding: MySQLConnectionEncoding) -> String? {
        guard let name = field.name else { return nil }
        let bytes = UnsafeRawBufferPointer(start: name, count: strnlen(name, Int(field.name_length)))
        return mysqlSessionText(bytes, encoding: encoding)
    }

    private static func run(_ statement: String, on mysql: UnsafeMutablePointer<MYSQL>) -> Bool {
        let status = statement.withCString { mysql_real_query(mysql, $0, UInt(strlen($0))) }
        if let discarded = mysql_store_result(mysql) {
            mysql_free_result(discarded)
        }
        return status == 0
    }

    private static func errorSummary(of mysql: UnsafeMutablePointer<MYSQL>, encoding: MySQLConnectionEncoding) -> String {
        let code = mysql_errno(mysql)
        guard let message = mysql_error(mysql) else { return "error \(code)" }
        return "\(code) \(mysqlSessionText(cString: message, encoding: encoding))"
    }
}

nonisolated func mysqlTypeToString(_ fieldPtr: UnsafePointer<MYSQL_FIELD>) -> String {
    let field = fieldPtr.pointee
    let flags = UInt(field.flags)

    // MariaDB extended metadata: detect JSON stored as LONGTEXT.
    // `MARIADB_CONST_STRING` is length-prefixed (not null-terminated), so we must read
    // exactly `attr.length` bytes. `String(cString:)` would scan past the buffer into
    // adjacent memory and intermittently fail the comparison when that memory is non-zero.
    var attr = MARIADB_CONST_STRING()
    if mariadb_field_attr(&attr, fieldPtr, MARIADB_FIELD_ATTR_FORMAT_NAME) == 0,
       let str = attr.str, attr.length > 0,
       let value = String(data: Data(bytes: str, count: Int(attr.length)), encoding: .utf8),
       value == "json" {
        return "JSON"
    }

    if (flags & mysqlEnumFlag) != 0 { return "ENUM" }
    if (flags & mysqlSetFlag) != 0 { return "SET" }

    return mariaDBTypeName(
        typeRaw: field.type.rawValue,
        flags: flags,
        charsetnr: field.charsetnr,
        length: field.length
    )
}
