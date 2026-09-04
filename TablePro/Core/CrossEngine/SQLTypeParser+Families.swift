//
//  SQLTypeParser+Families.swift
//  TablePro
//
//  One reading per family, kept apart so a word can mean two things.
//

import Foundation

internal extension SQLTypeParser {
    static func mysqlKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "BOOL", "BOOLEAN": return .boolean
        /// `TINYINT(1)` is how MySQL stores a boolean, and how every MySQL ORM writes one. Read as
        /// a one-byte integer it becomes a `SMALLINT` on the target and every `true` arrives as 1.
        case "TINYINT": return integers(in: params).first == 1 ? .boolean : .integer(bytes: 1)
        case "SMALLINT": return .integer(bytes: 2)
        case "MEDIUMINT": return .integer(bytes: 3)
        case "INT", "INTEGER": return .integer(bytes: 4)
        case "BIGINT": return .integer(bytes: 8)
        case "YEAR": return .integer(bytes: 2)
        case "BIT": return .bitString(length: length(params))
        case "DECIMAL", "NUMERIC", "DEC", "FIXED": return decimalKind(params)
        case "FLOAT": return .floatingPoint(bits: 32)
        case "DOUBLE", "DOUBLE PRECISION", "REAL": return .floatingPoint(bits: 64)
        case "CHAR", "NCHAR": return .text(length: length(params), isFixed: true)
        case "VARCHAR", "NVARCHAR", "CHARACTER VARYING": return .text(length: length(params), isFixed: false)
        case "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT": return .text(length: nil, isFixed: false)
        case "BINARY": return .binary(length: length(params), isFixed: true)
        case "VARBINARY": return .binary(length: length(params), isFixed: false)
        case "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB": return .binary(length: nil, isFixed: false)
        case "DATE": return .date
        case "TIME": return .time(precision: length(params), hasTimeZone: false)
        /// Both are wall-clock as far as DDL is concerned. `TIMESTAMP` is stored as UTC and read
        /// back in the session's zone, but it declares no zone and its values arrive without one.
        case "DATETIME", "TIMESTAMP": return .timestamp(precision: length(params), hasTimeZone: false)
        case "ENUM": return .enumeration(values: labels(in: params))
        case "JSON": return .json
        case "GEOMETRY", "POINT", "LINESTRING", "POLYGON", "MULTIPOINT",
             "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION": return .spatial
        default: return .unsupported
        }
    }

    static func postgresKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "BOOL", "BOOLEAN": return .boolean
        case "INT2", "SMALLINT", "SMALLSERIAL", "SERIAL2": return .integer(bytes: 2)
        case "INT4", "INT", "INTEGER", "SERIAL", "SERIAL4": return .integer(bytes: 4)
        case "INT8", "BIGINT", "BIGSERIAL", "SERIAL8": return .integer(bytes: 8)
        case "NUMERIC", "DECIMAL": return decimalKind(params)
        case "FLOAT4", "REAL": return .floatingPoint(bits: 32)
        case "FLOAT8", "DOUBLE PRECISION": return .floatingPoint(bits: 64)
        case "MONEY": return .money
        case "CHAR", "BPCHAR", "CHARACTER": return .text(length: length(params), isFixed: true)
        case "VARCHAR", "CHARACTER VARYING": return .text(length: length(params), isFixed: false)
        case "TEXT", "NAME", "CITEXT": return .text(length: nil, isFixed: false)
        case "BYTEA": return .binary(length: nil, isFixed: false)
        case "DATE": return .date
        case "TIME", "TIME WITHOUT TIME ZONE": return .time(precision: length(params), hasTimeZone: false)
        case "TIMETZ", "TIME WITH TIME ZONE": return .time(precision: length(params), hasTimeZone: true)
        case "TIMESTAMP", "TIMESTAMP WITHOUT TIME ZONE":
            return .timestamp(precision: length(params), hasTimeZone: false)
        case "TIMESTAMPTZ", "TIMESTAMP WITH TIME ZONE":
            return .timestamp(precision: length(params), hasTimeZone: true)
        case "INTERVAL": return .interval
        case "UUID": return .uuid
        case "JSON", "JSONB": return .json
        case "XML": return .xml
        case "BIT", "VARBIT", "BIT VARYING": return .bitString(length: length(params))
        case "GEOMETRY", "GEOGRAPHY", "BOX", "CIRCLE", "LINE", "LSEG", "PATH", "POINT", "POLYGON":
            return .spatial
        default: return .unsupported
        }
    }

    /// SQLite declares an affinity, not a type, and stores whatever spelling the `CREATE TABLE`
    /// used, so a table written by another tool carries that tool's words. The five affinity names
    /// are read first and anything else falls through to the ANSI reading rather than to
    /// `.unsupported`, which is what keeps a `VARCHAR(255)` in a SQLite file a `VARCHAR(255)`.
    static func sqliteKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "INTEGER", "INT": return .integer(bytes: 8)
        case "REAL": return .floatingPoint(bits: 64)
        case "TEXT": return .text(length: nil, isFixed: false)
        case "BLOB": return .binary(length: nil, isFixed: false)
        case "NUMERIC": return decimalKind(params)
        default: return ansiKind(base: base, params: params)
        }
    }

    static func mssqlKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "BIT": return .boolean
        case "TINYINT": return .integer(bytes: 1)
        case "SMALLINT": return .integer(bytes: 2)
        case "INT", "INTEGER": return .integer(bytes: 4)
        case "BIGINT": return .integer(bytes: 8)
        case "DECIMAL", "NUMERIC": return decimalKind(params)
        case "REAL": return .floatingPoint(bits: 32)
        /// `FLOAT(n)` is 32 bits up to a mantissa of 24 and 64 above it, which is why the parameter
        /// is read rather than assumed. `FLOAT` with none is 53, so 64.
        case "FLOAT": return .floatingPoint(bits: (length(params) ?? 53) <= 24 ? 32 : 64)
        case "MONEY", "SMALLMONEY": return .money
        case "CHAR", "NCHAR": return .text(length: length(params), isFixed: true)
        /// `varchar(max)` reaches here with no integer parameter, and so does a `varchar` with none
        /// at all; both are unbounded as far as the target is concerned.
        case "VARCHAR", "NVARCHAR": return .text(length: length(params), isFixed: false)
        case "TEXT", "NTEXT": return .text(length: nil, isFixed: false)
        case "BINARY": return .binary(length: length(params), isFixed: true)
        case "VARBINARY", "IMAGE": return .binary(length: length(params), isFixed: false)
        case "DATE": return .date
        case "TIME": return .time(precision: length(params), hasTimeZone: false)
        case "DATETIME", "DATETIME2", "SMALLDATETIME":
            return .timestamp(precision: length(params), hasTimeZone: false)
        case "DATETIMEOFFSET": return .timestamp(precision: length(params), hasTimeZone: true)
        case "UNIQUEIDENTIFIER": return .uuid
        case "XML": return .xml
        case "GEOMETRY", "GEOGRAPHY": return .spatial
        default: return .unsupported
        }
    }

    /// Oracle has one numeric type, so a whole-number column is a `NUMBER(p, 0)` and its precision
    /// is the only thing that says how wide an integer the target needs. Read as a decimal, an
    /// Oracle primary key arrives on MySQL as `DECIMAL(10,0)` and stops being an integer.
    static func oracleKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "NUMBER", "DECIMAL", "NUMERIC", "DEC":
            let numbers = integers(in: params)
            guard numbers.count > 1, numbers[1] == 0, let precision = numbers.first else {
                return decimalKind(params)
            }
            return .integer(bytes: integerWidth(forDecimalDigits: precision))
        case "INT", "INTEGER", "SMALLINT": return .integer(bytes: 4)
        case "FLOAT", "BINARY_DOUBLE", "DOUBLE PRECISION": return .floatingPoint(bits: 64)
        case "BINARY_FLOAT": return .floatingPoint(bits: 32)
        case "CHAR", "NCHAR": return .text(length: length(params), isFixed: true)
        case "VARCHAR", "VARCHAR2", "NVARCHAR2": return .text(length: length(params), isFixed: false)
        case "CLOB", "NCLOB", "LONG": return .text(length: nil, isFixed: false)
        case "ROWID", "UROWID": return .text(length: 18, isFixed: false)
        case "BLOB", "LONG RAW", "BFILE": return .binary(length: nil, isFixed: false)
        case "RAW": return .binary(length: length(params), isFixed: false)
        /// Oracle's `DATE` carries hours, minutes and seconds. Copied to a `DATE` on any other
        /// engine it loses the time of day silently.
        case "DATE": return .timestamp(precision: 0, hasTimeZone: false)
        case "TIMESTAMP": return .timestamp(precision: length(params), hasTimeZone: false)
        case "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE":
            return .timestamp(precision: length(params), hasTimeZone: true)
        case "XMLTYPE": return .xml
        case "SDO_GEOMETRY": return .spatial
        default:
            return base.hasPrefix("INTERVAL") ? .interval : .unsupported
        }
    }

    static func clickHouseKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "BOOL", "BOOLEAN": return .boolean
        case "INT8", "UINT8": return .integer(bytes: 1)
        case "INT16", "UINT16": return .integer(bytes: 2)
        case "INT32", "UINT32": return .integer(bytes: 4)
        case "INT64", "UINT64": return .integer(bytes: 8)
        case "INT128", "UINT128", "INT256", "UINT256": return .integer(bytes: 16)
        case "FLOAT32": return .floatingPoint(bits: 32)
        case "FLOAT64": return .floatingPoint(bits: 64)
        case "DECIMAL", "DECIMAL32", "DECIMAL64", "DECIMAL128", "DECIMAL256": return decimalKind(params)
        case "STRING": return .text(length: nil, isFixed: false)
        case "FIXEDSTRING": return .text(length: length(params), isFixed: true)
        case "DATE", "DATE32": return .date
        case "DATETIME", "DATETIME64": return .timestamp(precision: length(params), hasTimeZone: false)
        case "UUID": return .uuid
        case "JSON", "OBJECT": return .json
        case "ENUM", "ENUM8", "ENUM16": return .enumeration(values: labels(in: params))
        case "IPV4", "IPV6": return .text(length: 45, isFixed: false)
        default: return .unsupported
        }
    }

    static func duckDBKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "BOOL", "BOOLEAN", "LOGICAL": return .boolean
        case "TINYINT", "INT1", "UTINYINT": return .integer(bytes: 1)
        case "SMALLINT", "INT2", "SHORT", "USMALLINT": return .integer(bytes: 2)
        case "INTEGER", "INT", "INT4", "SIGNED", "UINTEGER": return .integer(bytes: 4)
        case "BIGINT", "INT8", "LONG", "UBIGINT": return .integer(bytes: 8)
        case "HUGEINT", "UHUGEINT": return .integer(bytes: 16)
        case "DECIMAL", "NUMERIC": return decimalKind(params)
        case "REAL", "FLOAT4", "FLOAT": return .floatingPoint(bits: 32)
        case "DOUBLE", "FLOAT8": return .floatingPoint(bits: 64)
        case "VARCHAR", "CHAR", "BPCHAR", "TEXT", "STRING": return .text(length: length(params), isFixed: false)
        case "BLOB", "BYTEA", "BINARY", "VARBINARY": return .binary(length: nil, isFixed: false)
        case "DATE": return .date
        case "TIME": return .time(precision: length(params), hasTimeZone: false)
        case "TIMETZ", "TIME WITH TIME ZONE": return .time(precision: length(params), hasTimeZone: true)
        case "TIMESTAMP", "DATETIME": return .timestamp(precision: length(params), hasTimeZone: false)
        case "TIMESTAMPTZ", "TIMESTAMP WITH TIME ZONE":
            return .timestamp(precision: length(params), hasTimeZone: true)
        case "INTERVAL": return .interval
        case "UUID": return .uuid
        case "JSON": return .json
        case "BIT", "BITSTRING": return .bitString(length: length(params))
        default: return .unsupported
        }
    }

    /// The words the SQL standard defines, for an engine no family here names. Nothing engine
    /// specific belongs in it: a plugin added later reads its own types through this, and a guess
    /// borrowed from one engine would be wrong for the next.
    static func ansiKind(base: String, params: String?) -> CanonicalTypeKind {
        switch base {
        case "BOOL", "BOOLEAN": return .boolean
        case "TINYINT", "BYTEINT": return .integer(bytes: 1)
        case "SMALLINT", "INT2": return .integer(bytes: 2)
        case "INT", "INTEGER", "INT4": return .integer(bytes: 4)
        case "BIGINT", "INT8", "LONG": return .integer(bytes: 8)
        case "DECIMAL", "NUMERIC", "DEC", "NUMBER": return decimalKind(params)
        case "REAL", "FLOAT4": return .floatingPoint(bits: 32)
        case "FLOAT", "DOUBLE", "DOUBLE PRECISION", "FLOAT8": return .floatingPoint(bits: 64)
        case "CHAR", "CHARACTER", "NCHAR": return .text(length: length(params), isFixed: true)
        case "VARCHAR", "CHARACTER VARYING", "NVARCHAR", "VARCHAR2", "STRING":
            return .text(length: length(params), isFixed: false)
        case "TEXT", "CLOB", "NCLOB": return .text(length: nil, isFixed: false)
        case "BINARY", "VARBINARY", "BLOB", "BYTEA", "BYTES":
            return .binary(length: length(params), isFixed: base == "BINARY")
        case "DATE": return .date
        case "TIME": return .time(precision: length(params), hasTimeZone: false)
        case "TIMETZ", "TIME WITH TIME ZONE": return .time(precision: length(params), hasTimeZone: true)
        case "TIMESTAMP", "DATETIME", "TIMESTAMP WITHOUT TIME ZONE":
            return .timestamp(precision: length(params), hasTimeZone: false)
        case "TIMESTAMPTZ", "TIMESTAMP WITH TIME ZONE":
            return .timestamp(precision: length(params), hasTimeZone: true)
        case "INTERVAL": return .interval
        case "UUID": return .uuid
        case "JSON", "JSONB", "VARIANT": return .json
        case "XML": return .xml
        default: return .unsupported
        }
    }

    /// The narrowest integer that holds every value of that many decimal digits. Oracle and
    /// Teradata both declare integers this way and nothing else says how wide the column is.
    static func integerWidth(forDecimalDigits digits: Int) -> Int {
        switch digits {
        case ..<3: return 1
        case ..<5: return 2
        case ..<10: return 4
        case ..<19: return 8
        default: return 16
        }
    }
}
