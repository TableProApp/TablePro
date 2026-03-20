//
//  DynamoDBQueryBuilder.swift
//  DynamoDBDriverPlugin
//
//  Builds internal tagged query strings for DynamoDB table browsing and filtering.
//

import Foundation
import TableProPluginKit

// MARK: - Parsed Query Types

struct DynamoDBParsedScanQuery {
    let tableName: String
    let limit: Int
    let offset: Int
    let filterColumn: String?
    let filterOp: String?
    let filterValue: String?
}

struct DynamoDBParsedQueryQuery {
    let tableName: String
    let partitionKeyName: String
    let partitionKeyValue: String
    let partitionKeyType: String
    let limit: Int
    let offset: Int
}

struct DynamoDBParsedCountQuery {
    let tableName: String
    let filterColumn: String?
    let filterOp: String?
    let filterValue: String?
}

// MARK: - Query Builder

struct DynamoDBQueryBuilder {
    static let scanTag = "DYNAMODB_SCAN:"
    static let queryTag = "DYNAMODB_QUERY:"
    static let countTag = "DYNAMODB_COUNT:"

    /// Build a browse query for the given table. If a partition key equality filter is found,
    /// emit a QUERY tag (more efficient). Otherwise emit a SCAN tag.
    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        Self.encodeScanQuery(tableName: table, limit: limit, offset: offset)
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        keySchema: [(name: String, keyType: String)]
    ) -> String? {
        // If there is a partition key equality filter, use QUERY for efficiency
        let partitionKey = keySchema.first(where: { $0.keyType == "HASH" })
        if let pk = partitionKey,
           let pkFilter = filters.first(where: { $0.column == pk.name && $0.op == "=" })
        {
            // Determine type from column name (default to S)
            let pkType = "S"
            return Self.encodeQueryQuery(
                tableName: table,
                partitionKeyName: pk.name,
                partitionKeyValue: pkFilter.value,
                partitionKeyType: pkType,
                limit: limit,
                offset: offset
            )
        }

        // Fall back to scan with first filter
        if let filter = filters.first {
            return Self.encodeScanQuery(
                tableName: table, limit: limit, offset: offset,
                filterColumn: filter.column, filterOp: filter.op, filterValue: filter.value
            )
        }

        return Self.encodeScanQuery(tableName: table, limit: limit, offset: offset)
    }

    func buildQuickSearchQuery(
        table: String,
        searchText: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        // Quick search uses a scan with a "contains" filter on all columns (client-side)
        Self.encodeScanQuery(
            tableName: table, limit: limit, offset: offset,
            filterColumn: "*", filterOp: "CONTAINS", filterValue: searchText
        )
    }

    func buildCombinedQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        searchText: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int,
        keySchema: [(name: String, keyType: String)]
    ) -> String? {
        if !searchText.isEmpty {
            return buildQuickSearchQuery(
                table: table, searchText: searchText,
                sortColumns: sortColumns, limit: limit, offset: offset
            )
        }
        return buildFilteredQuery(
            table: table, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, columns: [], limit: limit, offset: offset,
            keySchema: keySchema
        )
    }

    // MARK: - Encoding

    private static func encodeScanQuery(
        tableName: String,
        limit: Int,
        offset: Int,
        filterColumn: String? = nil,
        filterOp: String? = nil,
        filterValue: String? = nil
    ) -> String {
        let b64Table = Data(tableName.utf8).base64EncodedString()
        let b64FilterCol = Data((filterColumn ?? "").utf8).base64EncodedString()
        let b64FilterOp = Data((filterOp ?? "").utf8).base64EncodedString()
        let b64FilterVal = Data((filterValue ?? "").utf8).base64EncodedString()
        return "\(scanTag)\(b64Table):\(limit):\(offset):\(b64FilterCol):\(b64FilterOp):\(b64FilterVal)"
    }

    private static func encodeQueryQuery(
        tableName: String,
        partitionKeyName: String,
        partitionKeyValue: String,
        partitionKeyType: String,
        limit: Int,
        offset: Int
    ) -> String {
        let b64Table = Data(tableName.utf8).base64EncodedString()
        let b64PkName = Data(partitionKeyName.utf8).base64EncodedString()
        let b64PkValue = Data(partitionKeyValue.utf8).base64EncodedString()
        let b64PkType = Data(partitionKeyType.utf8).base64EncodedString()
        return "\(queryTag)\(b64Table):\(limit):\(offset):\(b64PkName):\(b64PkValue):\(b64PkType)"
    }

    static func encodeCountQuery(
        tableName: String,
        filterColumn: String? = nil,
        filterOp: String? = nil,
        filterValue: String? = nil
    ) -> String {
        let b64Table = Data(tableName.utf8).base64EncodedString()
        let b64FilterCol = Data((filterColumn ?? "").utf8).base64EncodedString()
        let b64FilterOp = Data((filterOp ?? "").utf8).base64EncodedString()
        let b64FilterVal = Data((filterValue ?? "").utf8).base64EncodedString()
        return "\(countTag)\(b64Table):\(b64FilterCol):\(b64FilterOp):\(b64FilterVal)"
    }

    // MARK: - Decoding

    static func parseScanQuery(_ query: String) -> DynamoDBParsedScanQuery? {
        guard query.hasPrefix(scanTag) else { return nil }
        let body = String(query.dropFirst(scanTag.count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 6 else { return nil }

        guard let tableData = Data(base64Encoded: parts[0]),
              let tableName = String(data: tableData, encoding: .utf8),
              let limit = Int(parts[1]),
              let offset = Int(parts[2])
        else { return nil }

        let filterColumn = decodeBase64(parts[3])
        let filterOp = decodeBase64(parts[4])
        let filterValue = decodeBase64(parts[5...].joined(separator: ":"))

        return DynamoDBParsedScanQuery(
            tableName: tableName,
            limit: limit,
            offset: offset,
            filterColumn: filterColumn?.isEmpty == true ? nil : filterColumn,
            filterOp: filterOp?.isEmpty == true ? nil : filterOp,
            filterValue: filterValue?.isEmpty == true ? nil : filterValue
        )
    }

    static func parseQueryQuery(_ query: String) -> DynamoDBParsedQueryQuery? {
        guard query.hasPrefix(queryTag) else { return nil }
        let body = String(query.dropFirst(queryTag.count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 6 else { return nil }

        guard let tableData = Data(base64Encoded: parts[0]),
              let tableName = String(data: tableData, encoding: .utf8),
              let limit = Int(parts[1]),
              let offset = Int(parts[2]),
              let pkName = decodeBase64(parts[3]),
              let pkValue = decodeBase64(parts[4]),
              let pkType = decodeBase64(parts[5...].joined(separator: ":"))
        else { return nil }

        return DynamoDBParsedQueryQuery(
            tableName: tableName,
            partitionKeyName: pkName,
            partitionKeyValue: pkValue,
            partitionKeyType: pkType,
            limit: limit,
            offset: offset
        )
    }

    static func parseCountQuery(_ query: String) -> DynamoDBParsedCountQuery? {
        guard query.hasPrefix(countTag) else { return nil }
        let body = String(query.dropFirst(countTag.count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 4 else { return nil }

        guard let tableData = Data(base64Encoded: parts[0]),
              let tableName = String(data: tableData, encoding: .utf8)
        else { return nil }

        let filterColumn = decodeBase64(parts[1])
        let filterOp = decodeBase64(parts[2])
        let filterValue = decodeBase64(parts[3...].joined(separator: ":"))

        return DynamoDBParsedCountQuery(
            tableName: tableName,
            filterColumn: filterColumn?.isEmpty == true ? nil : filterColumn,
            filterOp: filterOp?.isEmpty == true ? nil : filterOp,
            filterValue: filterValue?.isEmpty == true ? nil : filterValue
        )
    }

    static func isTaggedQuery(_ query: String) -> Bool {
        query.hasPrefix(scanTag) || query.hasPrefix(queryTag) || query.hasPrefix(countTag)
    }

    // MARK: - Helpers

    private static func decodeBase64(_ string: String) -> String? {
        guard let data = Data(base64Encoded: string),
              let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded
    }
}
