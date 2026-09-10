//
//  EtcdQueryBuilder.swift
//  EtcdDriverPlugin
//
//  Builds internal query strings for etcd key browsing and filtering.
//

import Foundation
import TableProPluginKit

enum EtcdFilterType: String {
    case none
    case contains
    case startsWith
    case endsWith
    case equals
}

struct EtcdParsedQuery {
    let prefix: String
    let limit: Int
    let offset: Int
    let sortAscending: Bool
    let filterType: EtcdFilterType
    let filterValue: String
    var isCaseSensitive = false
}

struct EtcdParsedCountQuery {
    let prefix: String
    let filterType: EtcdFilterType
    let filterValue: String
    var isCaseSensitive = false
}

struct EtcdQueryBuilder {
    static let rangeTag = "ETCD_RANGE:"
    static let countTag = "ETCD_COUNT:"

    func buildBrowseQuery(
        prefix: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        let sortAsc = sortColumns.first?.ascending ?? true
        return Self.encodeRangeQuery(
            prefix: prefix, limit: limit, offset: offset,
            sortAscending: sortAsc, filterType: .none, filterValue: "", isCaseSensitive: false
        )
    }

    func buildFilteredQuery(
        prefix: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String? {
        if hasUnsupportedFilters(filters) { return nil }
        let sortAsc = sortColumns.first?.ascending ?? true
        let (filterType, filterValue) = extractKeyFilter(from: filters)
        let isCaseSensitive = filters.first { $0.column == "Key" }?.isCaseSensitive ?? true
        return Self.encodeRangeQuery(
            prefix: prefix, limit: limit, offset: offset,
            sortAscending: sortAsc, filterType: filterType, filterValue: filterValue,
            isCaseSensitive: isCaseSensitive
        )
    }

    func buildCountQuery(prefix: String) -> String {
        Self.encodeCountQuery(prefix: prefix, filterType: .none, filterValue: "", isCaseSensitive: false)
    }

    // MARK: - Encoding

    private static func encodeRangeQuery(
        prefix: String, limit: Int, offset: Int,
        sortAscending: Bool, filterType: EtcdFilterType, filterValue: String,
        isCaseSensitive: Bool
    ) -> String {
        let b64Prefix = Data(prefix.utf8).base64EncodedString()
        let b64Filter = Data(filterValue.utf8).base64EncodedString()
        return "\(rangeTag)\(b64Prefix):\(limit):\(offset):\(sortAscending ? "1" : "0")"
            + ":\(filterType.rawValue):\(b64Filter):\(isCaseSensitive ? "1" : "0")"
    }

    private static func encodeCountQuery(
        prefix: String, filterType: EtcdFilterType, filterValue: String,
        isCaseSensitive: Bool
    ) -> String {
        let b64Prefix = Data(prefix.utf8).base64EncodedString()
        let b64Filter = Data(filterValue.utf8).base64EncodedString()
        return "\(countTag)\(b64Prefix):\(filterType.rawValue):\(b64Filter):\(isCaseSensitive ? "1" : "0")"
    }

    // MARK: - Decoding

    private static func decodeBase64Segment(_ segment: String) -> String {
        guard let data = Data(base64Encoded: segment),
              let decoded = String(data: data, encoding: .utf8) else { return "" }
        return decoded
    }

    static func parseRangeQuery(_ query: String) -> EtcdParsedQuery? {
        guard query.hasPrefix(rangeTag) else { return nil }
        let body = String(query.dropFirst(rangeTag.count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 6 else { return nil }

        guard let prefixData = Data(base64Encoded: parts[0]),
              let prefix = String(data: prefixData, encoding: .utf8),
              let limit = Int(parts[1]),
              let offset = Int(parts[2]) else { return nil }

        let sortAscending = parts[3] == "1"
        let filterType = EtcdFilterType(rawValue: parts[4]) ?? .none

        let filterValue = decodeBase64Segment(parts[5])

        return EtcdParsedQuery(
            prefix: prefix, limit: limit, offset: offset,
            sortAscending: sortAscending, filterType: filterType, filterValue: filterValue,
            isCaseSensitive: parts.count > 6 && parts[6] == "1"
        )
    }

    static func parseCountQuery(_ query: String) -> EtcdParsedCountQuery? {
        guard query.hasPrefix(countTag) else { return nil }
        let body = String(query.dropFirst(countTag.count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 3 else { return nil }

        guard let prefixData = Data(base64Encoded: parts[0]),
              let prefix = String(data: prefixData, encoding: .utf8) else { return nil }

        let filterType = EtcdFilterType(rawValue: parts[1]) ?? .none
        let filterValue = decodeBase64Segment(parts[2])

        return EtcdParsedCountQuery(
            prefix: prefix, filterType: filterType, filterValue: filterValue,
            isCaseSensitive: parts.count > 3 && parts[3] == "1"
        )
    }

    static func isTaggedQuery(_ query: String) -> Bool {
        query.hasPrefix(rangeTag) || query.hasPrefix(countTag)
    }

    // MARK: - Filter Extraction

    /// Returns true if any filter targets a column other than "Key",
    /// which etcd cannot handle server-side (Value, Lease, Version, etc.).
    private func hasUnsupportedFilters(_ filters: [PluginQueryFilter]) -> Bool {
        filters.contains { $0.column != "Key" }
    }

    private func extractKeyFilter(from filters: [PluginQueryFilter]) -> (EtcdFilterType, String) {
        let keyFilters = filters.filter { $0.column == "Key" }
        guard let filter = keyFilters.first else { return (.none, "") }

        switch filter.op {
        case "CONTAINS": return (.contains, filter.value)
        case "STARTS WITH": return (.startsWith, filter.value)
        case "ENDS WITH": return (.endsWith, filter.value)
        case "=": return (.equals, filter.value)
        default: return (.none, "")
        }
    }
}
