import Foundation
import TableProModels

nonisolated internal enum RedisQueryResultBuilder {
    static let rowLimit = 100_000

    static func result(for reply: RedisReplyValue, executionTime: TimeInterval) throws -> QueryResult {
        switch reply {
        case .error(let message):
            throw RedisError.queryFailed(message)
        case .string(let value):
            return singleValue(value, typeName: "string", executionTime: executionTime)
        case .integer(let value):
            return singleValue(String(value), typeName: "integer", executionTime: executionTime)
        case .null:
            return singleValue(nil, typeName: "string", executionTime: executionTime)
        case .status(let value):
            return QueryResult(
                columns: [ColumnInfo(name: "status", typeName: "string", ordinalPosition: 0)],
                rows: [[value]],
                rowsAffected: 0,
                executionTime: executionTime,
                statusMessage: value
            )
        case .array(let items):
            if isHashResult(items) {
                return pairedResult(items, executionTime: executionTime)
            }
            return indexedResult(items, executionTime: executionTime)
        }
    }

    private static func singleValue(_ value: String?, typeName: String, executionTime: TimeInterval) -> QueryResult {
        QueryResult(
            columns: [ColumnInfo(name: "value", typeName: typeName, ordinalPosition: 0)],
            rows: [[value]],
            rowsAffected: 0,
            executionTime: executionTime
        )
    }

    private static func pairedResult(_ items: [RedisReplyValue], executionTime: TimeInterval) -> QueryResult {
        let rows: [[String?]] = stride(from: 0, to: items.count - 1, by: 2).map { index in
            [items[index].stringRepresentation, items[index + 1].stringRepresentation]
        }
        return QueryResult(
            columns: [
                ColumnInfo(name: "key", typeName: "string", ordinalPosition: 0),
                ColumnInfo(name: "value", typeName: "string", ordinalPosition: 1)
            ],
            rows: rows,
            rowsAffected: 0,
            executionTime: executionTime,
            isTruncated: rows.count >= rowLimit
        )
    }

    private static func indexedResult(_ items: [RedisReplyValue], executionTime: TimeInterval) -> QueryResult {
        let rows: [[String?]] = items.prefix(rowLimit).enumerated().map { index, item in
            [String(index), item.stringRepresentation]
        }
        return QueryResult(
            columns: [
                ColumnInfo(name: "index", typeName: "integer", ordinalPosition: 0),
                ColumnInfo(name: "value", typeName: "string", ordinalPosition: 1)
            ],
            rows: rows,
            rowsAffected: 0,
            executionTime: executionTime,
            isTruncated: items.count > rowLimit
        )
    }

    private static func isHashResult(_ items: [RedisReplyValue]) -> Bool {
        guard items.count >= 2, items.count.isMultiple(of: 2) else { return false }
        return stride(from: 0, to: items.count, by: 2).allSatisfy { index in
            if case .string = items[index] { return true }
            return false
        }
    }
}
