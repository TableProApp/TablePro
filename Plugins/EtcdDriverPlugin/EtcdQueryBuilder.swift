//
//  EtcdQueryBuilder.swift
//  EtcdDriverPlugin
//
//  Builds internal query strings for etcd key browsing and filtering.
//

import Foundation
import TableProPluginKit

struct EtcdParsedQuery {
    let prefix: String
    let limit: Int
    let offset: Int
    let sortAscending: Bool
    let filter: EtcdRowFilter
}

struct EtcdParsedCountQuery {
    let prefix: String
}

struct EtcdQueryBuilder {
    static let rangeTag = "ETCD_RANGE:"
    static let countTag = "ETCD_COUNT:"
    static let refusalTag = "ETCD_REFUSAL:"

    func buildBrowseQuery(
        prefix: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        Self.encodeRangeQuery(
            prefix: prefix, limit: limit, offset: offset,
            sortAscending: sortColumns.first?.ascending ?? true, filter: .unfiltered
        )
    }

    func buildFilteredQuery(
        prefix: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        do throws(EtcdFilterRefusal) {
            let filter = try EtcdRowFilter(filters: filters, logicMode: logicMode)
            return Self.encodeRangeQuery(
                prefix: prefix, limit: limit, offset: offset,
                sortAscending: sortColumns.first?.ascending ?? true, filter: filter
            )
        } catch {
            return Self.refusalTag + Self.encodeSegment(error.pluginErrorMessage)
        }
    }

    func buildCountQuery(prefix: String) -> String {
        Self.countTag + Self.encodeSegment(prefix)
    }

    // MARK: - Encoding

    private static func encodeRangeQuery(
        prefix: String, limit: Int, offset: Int, sortAscending: Bool, filter: EtcdRowFilter
    ) -> String {
        "\(rangeTag)\(encodeSegment(prefix)):\(limit):\(offset):\(sortAscending ? "1" : "0"):\(encodeFilter(filter))"
    }

    private static func encodeSegment(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private static func encodeFilter(_ filter: EtcdRowFilter) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ((try? encoder.encode(filter)) ?? Data()).base64EncodedString()
    }

    // MARK: - Decoding

    private static func decodeSegment(_ segment: String) -> String? {
        guard let data = Data(base64Encoded: segment) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeFilter(_ segment: String) -> EtcdRowFilter? {
        guard let data = Data(base64Encoded: segment) else { return nil }
        return try? JSONDecoder().decode(EtcdRowFilter.self, from: data)
    }

    static func parseRangeQuery(_ query: String) -> EtcdParsedQuery? {
        guard query.hasPrefix(rangeTag) else { return nil }
        let parts = query.dropFirst(rangeTag.count).components(separatedBy: ":")
        guard parts.count == 5,
              let prefix = decodeSegment(parts[0]),
              let limit = Int(parts[1]),
              let offset = Int(parts[2]),
              let filter = decodeFilter(parts[4]) else { return nil }
        return EtcdParsedQuery(
            prefix: prefix, limit: limit, offset: offset, sortAscending: parts[3] == "1", filter: filter
        )
    }

    static func parseCountQuery(_ query: String) -> EtcdParsedCountQuery? {
        guard query.hasPrefix(countTag),
              let prefix = decodeSegment(String(query.dropFirst(countTag.count))) else { return nil }
        return EtcdParsedCountQuery(prefix: prefix)
    }

    static func parseRefusal(_ query: String) -> EtcdFilterRefusal? {
        guard query.hasPrefix(refusalTag),
              let message = decodeSegment(String(query.dropFirst(refusalTag.count))) else { return nil }
        return EtcdFilterRefusal(pluginErrorMessage: message)
    }

    static func isTaggedQuery(_ query: String) -> Bool {
        query.hasPrefix(rangeTag) || query.hasPrefix(countTag) || query.hasPrefix(refusalTag)
    }
}
