//
//  TypesenseQueryBuilder.swift
//  TypesenseDriverPlugin
//
//  Encodes browse and filter requests as tagged strings and builds search parameters.
//

import Foundation
import TableProPluginKit

struct TypesenseSortSpec: Codable, Equatable {
    let column: String
    let ascending: Bool
}

struct TypesenseParsedSearch: Equatable {
    let collection: String
    let offset: Int
    let limit: Int
    let sorts: [TypesenseSortSpec]
    let filters: [TypesenseFilterSpec]
    let logicMode: String

    func replacingSorts(_ sorts: [TypesenseSortSpec]) -> TypesenseParsedSearch {
        TypesenseParsedSearch(
            collection: collection, offset: offset, limit: limit,
            sorts: sorts, filters: filters, logicMode: logicMode
        )
    }
}

struct TypesenseSearchChunk: Equatable {
    let offset: Int
    let limit: Int
}

enum TypesenseQueryBuilder {
    static let searchTag = "TYPESENSE_SEARCH:"

    /// "Only upto 250 hits can be fetched per page", for `per_page` and for `limit` alike. The
    /// default page in TablePro is 1,000 rows, so a browse is always more than one request.
    static let maxHitsPerRequest = 250

    /// "Only upto 3 sort fields can be specified in a single search query."
    static let maxSortFields = 3

    /// `limit_multi_searches` defaults to 50, and the 51st search answers 400 for the whole batch.
    static let maxSearchesPerRequest = 50

    // MARK: - Tagged Encoding

    static func encodeSearch(
        collection: String,
        offset: Int,
        limit: Int,
        sorts: [TypesenseSortSpec],
        filters: [TypesenseFilterSpec],
        logicMode: String
    ) -> String {
        let encodedCollection = Data(collection.utf8).base64EncodedString()
        let encodedSorts = ((try? JSONEncoder().encode(sorts)) ?? Data()).base64EncodedString()
        let encodedFilters = ((try? JSONEncoder().encode(filters)) ?? Data()).base64EncodedString()
        let encodedLogic = Data(logicMode.utf8).base64EncodedString()
        return "\(searchTag)\(encodedCollection):\(offset):\(limit):\(encodedSorts):\(encodedFilters):\(encodedLogic)"
    }

    static func parseSearch(_ query: String) -> TypesenseParsedSearch? {
        guard query.hasPrefix(searchTag) else { return nil }
        let parts = String(query.dropFirst(searchTag.count)).components(separatedBy: ":")
        guard parts.count >= 6,
              let collectionData = Data(base64Encoded: parts[0]),
              let collection = String(data: collectionData, encoding: .utf8),
              let offset = Int(parts[1]),
              let limit = Int(parts[2])
        else { return nil }

        let sorts = Data(base64Encoded: parts[3])
            .flatMap { try? JSONDecoder().decode([TypesenseSortSpec].self, from: $0) } ?? []
        let filters = Data(base64Encoded: parts[4])
            .flatMap { try? JSONDecoder().decode([TypesenseFilterSpec].self, from: $0) } ?? []
        let logicMode = Data(base64Encoded: parts[5])
            .flatMap { String(data: $0, encoding: .utf8) } ?? "AND"

        return TypesenseParsedSearch(
            collection: collection, offset: offset, limit: limit,
            sorts: sorts, filters: filters, logicMode: logicMode
        )
    }

    static func isTaggedQuery(_ query: String) -> Bool {
        query.hasPrefix(searchTag)
    }

    // MARK: - Appended ORDER BY

    /// The data grid appends a SQL `ORDER BY` clause to the opaque tagged query when the user
    /// sorts a column. Split it off and parse it into sort specs.
    static func extractOrderBy(_ query: String) -> (base: String, sorts: [TypesenseSortSpec]) {
        guard let range = query.range(of: " ORDER BY ", options: .caseInsensitive) else {
            return (query, [])
        }
        let base = String(query[..<range.lowerBound])
        var clause = String(query[range.upperBound...])
        for keyword in [" LIMIT ", " OFFSET ", ";"] {
            if let stop = clause.range(of: keyword, options: .caseInsensitive) {
                clause = String(clause[..<stop.lowerBound])
            }
        }
        return (base, parseOrderByClause(clause))
    }

    static func parseOrderByClause(_ clause: String) -> [TypesenseSortSpec] {
        clause.split(separator: ",").compactMap { rawPart in
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { return nil }

            let column: String
            var remainder: Substring
            if part.hasPrefix("\"") {
                let afterQuote = part.dropFirst()
                guard let closing = afterQuote.firstIndex(of: "\"") else { return nil }
                column = String(afterQuote[..<closing])
                remainder = afterQuote[afterQuote.index(after: closing)...]
            } else {
                let tokens = part.split(separator: " ", maxSplits: 1)
                column = String(tokens[0])
                remainder = tokens.count > 1 ? tokens[1] : ""
            }

            return TypesenseSortSpec(column: column, ascending: !remainder.uppercased().contains("DESC"))
        }
    }

    // MARK: - Search Parameters

    /// Sorting a field whose schema says `sort: false` is a 400 that fails the whole search, so an
    /// unsortable column is dropped rather than sent. `id` is never sortable.
    static func sortBy(_ sorts: [TypesenseSortSpec], fields: [String: TypesenseField]) -> String? {
        let sortable = sorts
            .filter { fields[$0.column]?.isSortable == true }
            .prefix(maxSortFields)
            .map { "\($0.column):\($0.ascending ? "asc" : "desc")" }
        return sortable.isEmpty ? nil : sortable.joined(separator: ",")
    }

    /// Splits a page into requests Typesense will accept. `offset` has no documented ceiling and
    /// answers correctly past a million, so deep paging needs no cursor.
    static func chunks(offset: Int, limit: Int) -> [TypesenseSearchChunk] {
        guard limit > 0 else { return [] }
        let start = max(0, offset)
        return stride(from: 0, to: limit, by: maxHitsPerRequest).map { taken in
            TypesenseSearchChunk(
                offset: start + taken,
                limit: min(maxHitsPerRequest, limit - taken)
            )
        }
    }

    /// A search goes over as a `POST /multi_search` body rather than a query string. Measured on
    /// 29.0, `GET /collections/:c/documents/search` answers 400 once the URL passes 4,096 bytes,
    /// which an `IN` filter reaches at 265 values; the same filter is fine in a body.
    static func searchBody(
        collection: String,
        chunk: TypesenseSearchChunk,
        filterBy: String?,
        sortBy: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "collection": collection,
            "q": "*",
            "offset": chunk.offset,
            "limit": chunk.limit,
        ]
        if let filterBy { body["filter_by"] = filterBy }
        if let sortBy { body["sort_by"] = sortBy }
        return body
    }

    static func countBody(collection: String, filterBy: String?) -> [String: Any] {
        var body: [String: Any] = [
            "collection": collection,
            "q": "*",
            "per_page": 0,
        ]
        if let filterBy { body["filter_by"] = filterBy }
        return body
    }

    static func multiSearchBody(_ searches: [[String: Any]]) -> [String: Any] {
        ["searches": searches]
    }

    /// One `multi_search` carries a whole 1,000-row page as four searches, so a page is one round
    /// trip rather than four. Past 50 searches the server rejects the entire batch.
    static func batches<Element>(_ elements: [Element]) -> [[Element]] {
        stride(from: 0, to: elements.count, by: maxSearchesPerRequest).map { start in
            Array(elements[start ..< min(start + maxSearchesPerRequest, elements.count)])
        }
    }
}
