//
//  CassandraStatementBinder.swift
//  CassandraDriverPlugin
//

#if canImport(CCassandra)
import CCassandra
#endif
import Foundation
import TableProPluginKit

enum CassandraStatementBinder {
    static func bind(_ values: [PluginCellValue], to statement: OpaquePointer, prepared: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let type = parameterType(of: prepared, at: index)
            let bound = try CassandraValueParser.bind(value, as: type)
            try check(bind(bound, to: statement, at: index), value: value, type: type)
        }
    }

    static func parameterType(of prepared: OpaquePointer, at index: Int) -> CassandraParameterType {
        guard let dataType = cass_prepared_parameter_data_type(prepared, index) else {
            return .unsupported("unknown")
        }
        return parameterType(cass_data_type_type(dataType))
    }

    static func parameterType(_ valueType: CassValueType) -> CassandraParameterType {
        switch valueType {
        case CASS_VALUE_TYPE_ASCII, CASS_VALUE_TYPE_TEXT, CASS_VALUE_TYPE_VARCHAR: return .text
        case CASS_VALUE_TYPE_TINY_INT: return .tinyint
        case CASS_VALUE_TYPE_SMALL_INT: return .smallint
        case CASS_VALUE_TYPE_INT: return .int
        case CASS_VALUE_TYPE_BIGINT: return .bigint
        case CASS_VALUE_TYPE_COUNTER: return .counter
        case CASS_VALUE_TYPE_FLOAT: return .float
        case CASS_VALUE_TYPE_DOUBLE: return .double
        case CASS_VALUE_TYPE_BOOLEAN: return .boolean
        case CASS_VALUE_TYPE_UUID: return .uuid
        case CASS_VALUE_TYPE_TIMEUUID: return .timeuuid
        case CASS_VALUE_TYPE_TIMESTAMP: return .timestamp
        case CASS_VALUE_TYPE_DATE: return .date
        case CASS_VALUE_TYPE_TIME: return .time
        case CASS_VALUE_TYPE_INET: return .inet
        case CASS_VALUE_TYPE_BLOB: return .blob
        case CASS_VALUE_TYPE_DECIMAL: return .decimal
        case CASS_VALUE_TYPE_VARINT: return .varint
        case CASS_VALUE_TYPE_LIST: return .unsupported("list")
        case CASS_VALUE_TYPE_SET: return .unsupported("set")
        case CASS_VALUE_TYPE_MAP: return .unsupported("map")
        case CASS_VALUE_TYPE_TUPLE: return .unsupported("tuple")
        case CASS_VALUE_TYPE_UDT: return .unsupported("user-defined type")
        case CASS_VALUE_TYPE_DURATION: return .unsupported("duration")
        default: return .unsupported("custom")
        }
    }

    private static func check(_ result: CassError, value: PluginCellValue, type: CassandraParameterType) throws {
        guard result != CASS_OK else { return }
        throw CassandraValueRefusal.invalid(value.asText ?? "", typeName: type.name)
    }

    private static func bind(_ value: CassandraBoundValue, to statement: OpaquePointer, at index: Int) -> CassError {
        switch value {
        case .null:
            return cass_statement_bind_null(statement, index)
        case .string(let text):
            return cass_statement_bind_string(statement, index, text)
        case .int8(let number):
            return cass_statement_bind_int8(statement, index, number)
        case .int16(let number):
            return cass_statement_bind_int16(statement, index, number)
        case .int32(let number):
            return cass_statement_bind_int32(statement, index, number)
        case .int64(let number), .time(let number):
            return cass_statement_bind_int64(statement, index, number)
        case .date(let days):
            return cass_statement_bind_uint32(statement, index, days)
        case .float(let number):
            return cass_statement_bind_float(statement, index, number)
        case .double(let number):
            return cass_statement_bind_double(statement, index, number)
        case .bool(let flag):
            return cass_statement_bind_bool(statement, index, flag ? cass_true : cass_false)
        case .uuid(let text):
            var uuid = CassUuid()
            let parsed = cass_uuid_from_string(text, &uuid)
            guard parsed == CASS_OK else { return parsed }
            return cass_statement_bind_uuid(statement, index, uuid)
        case .inet(let text):
            var inet = CassInet()
            let parsed = cass_inet_from_string(text, &inet)
            guard parsed == CASS_OK else { return parsed }
            return cass_statement_bind_inet(statement, index, inet)
        case .bytes(let data), .varint(let data):
            return data.withUnsafeBytes { buffer in
                let base = buffer.bindMemory(to: UInt8.self).baseAddress
                return cass_statement_bind_bytes(statement, index, base, data.count)
            }
        case .decimal(let unscaled, let scale):
            return unscaled.withUnsafeBytes { buffer in
                let base = buffer.bindMemory(to: UInt8.self).baseAddress
                return cass_statement_bind_decimal(statement, index, base, unscaled.count, scale)
            }
        }
    }
}
