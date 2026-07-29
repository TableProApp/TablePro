//
//  ElasticsearchPluginDriver+Execution.swift
//  ElasticsearchDriverPlugin
//
//  Query routing, search execution, and response rendering.
//

import Foundation
import TableProPluginKit

extension ElasticsearchPluginDriver {
    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()
        guard let conn = connection else { throw ElasticsearchError.notConnected }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased() == "select 1" {
            try await conn.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["integer"],
                rows: [[.text("1")]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        if ElasticsearchQueryBuilder.isTaggedQuery(trimmed) {
            return try await executeSearch(trimmed, conn: conn, startTime: startTime)
        }

        if ElasticsearchStatementGenerator.isTaggedStatement(trimmed) {
            return try await executeWrite(trimmed, conn: conn, startTime: startTime)
        }

        return try await executeConsole(trimmed, conn: conn, startTime: startTime)
    }

    // MARK: - Search

    private func executeSearch(
        _ query: String,
        conn: ElasticsearchConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let (base, appendedSorts) = ElasticsearchQueryBuilder.extractOrderBy(query)
        guard let parsedBase = ElasticsearchQueryBuilder.parseSearch(base) else {
            throw ElasticsearchError.invalidResponse("Invalid search request")
        }
        let parsed = appendedSorts.isEmpty ? parsedBase : ElasticsearchParsedSearch(
            index: parsedBase.index, from: parsedBase.from, size: parsedBase.size,
            sorts: appendedSorts, filters: parsedBase.filters, logicMode: parsedBase.logicMode
        )

        let mappingColumns = try await cachedMappingColumns(parsed.index)
        let fields = ElasticsearchMappingFlattener.fieldInfo(from: mappingColumns)

        Self.logger.debug("""
        executeSearch index=\(parsed.index, privacy: .public) from=\(parsed.from) size=\(parsed.size) \
        logic=\(parsed.logicMode, privacy: .public) \
        filters=\(parsed.filters.map { "\($0.column) \($0.op) \($0.value)" }.joined(separator: " | "), privacy: .public) \
        sorts=\(parsed.sorts.map { "\($0.column) \($0.ascending ? "asc" : "desc")" }.joined(separator: " | "), privacy: .public) \
        fieldInfoCount=\(fields.count) \
        fields=\(fields.map { "\($0.key):\($0.value.type)\($0.value.hasKeywordSubfield ? "+kw" : "")" }.sorted().joined(separator: ","), privacy: .public)
        """)

        let hits = try await fetchHits(index: parsed.index, parsed: parsed, fields: fields, conn: conn)

        return renderHits(hits, mappingColumns: mappingColumns, fields: fields, startTime: startTime)
    }

    private func fetchHits(
        index: String,
        parsed: ElasticsearchParsedSearch,
        fields: [String: ElasticsearchFieldInfo],
        conn: ElasticsearchConnection
    ) async throws -> [[String: Any]] {
        if parsed.from + parsed.size <= Self.maxResultWindow {
            var body = ElasticsearchQueryBuilder.searchBody(
                for: parsed, fields: fields, size: parsed.size, caseInsensitive: supportsCaseInsensitiveSearch
            )
            body["from"] = parsed.from
            Self.logger.debug("POST /\(index, privacy: .public)/_search body=\(Self.jsonString(body), privacy: .public)")
            let response = try await conn.search(index: index, body: body)
            let hits = extractHits(response)
            Self.logger.debug("_search returned \(hits.count) hit(s) for index=\(index, privacy: .public)")
            return hits
        }
        return try await deepFetchHits(index: index, parsed: parsed, fields: fields, conn: conn)
    }

    private func deepFetchHits(
        index: String,
        parsed: ElasticsearchParsedSearch,
        fields: [String: ElasticsearchFieldInfo],
        conn: ElasticsearchConnection
    ) async throws -> [[String: Any]] {
        let pit = try await conn.openPointInTime(index: index, keepAlive: Self.pitKeepAlive)
        do {
            let hits = try await collectDeepHits(parsed: parsed, fields: fields, pit: pit, conn: conn)
            await conn.closePointInTime(id: pit)
            return hits
        } catch {
            await conn.closePointInTime(id: pit)
            throw error
        }
    }

    private func collectDeepHits(
        parsed: ElasticsearchParsedSearch,
        fields: [String: ElasticsearchFieldInfo],
        pit: String,
        conn: ElasticsearchConnection
    ) async throws -> [[String: Any]] {
        var searchAfter: [Any]?
        var skipped = 0
        var collected: [[String: Any]] = []

        while collected.count < parsed.size {
            try Task.checkCancellation()
            var body = ElasticsearchQueryBuilder.searchBody(
                for: parsed, fields: fields, size: Self.deepPageBatchSize,
                tiebreaker: true, searchAfter: searchAfter, caseInsensitive: supportsCaseInsensitiveSearch
            )
            body["pit"] = ["id": pit, "keep_alive": Self.pitKeepAlive]
            let response = try await conn.search(index: nil, body: body)
            let hits = extractHits(response)
            guard !hits.isEmpty else { break }

            for hit in hits {
                if skipped < parsed.from {
                    skipped += 1
                } else if collected.count < parsed.size {
                    collected.append(hit)
                }
                searchAfter = hit["sort"] as? [Any]
            }

            if hits.count < Self.deepPageBatchSize { break }
        }

        return collected
    }

    // MARK: - Write

    private func executeWrite(
        _ statement: String,
        conn: ElasticsearchConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard let request = ElasticsearchStatementGenerator.decode(statement) else {
            throw ElasticsearchError.invalidResponse("Invalid write request")
        }

        let response = try await conn.request(method: request.method, path: request.path, body: request.body)
        guard (200..<300).contains(response.statusCode) else {
            throw mapWriteError(response)
        }

        let outcome = (response.json as? [String: Any])?["result"] as? String ?? "ok"
        return PluginQueryResult(
            columns: ["result"],
            columnTypeNames: ["keyword"],
            rows: [[.text(outcome)]],
            rowsAffected: 1,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Console

    private func executeConsole(
        _ input: String,
        conn: ElasticsearchConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard let request = ElasticsearchConsoleParser.parse(input) else {
            throw ElasticsearchError.invalidResponse(
                String(localized: "Enter a request like: GET /my-index/_search")
            )
        }

        let response = try await conn.request(method: request.method, path: request.path, body: request.body)
        guard (200..<300).contains(response.statusCode) else {
            throw mapWriteError(response)
        }

        if let json = response.json as? [String: Any],
           json["hits"] is [String: Any],
           json["aggregations"] == nil,
           json["suggest"] == nil {
            let hits = extractHits(response)
            return renderHits(hits, mappingColumns: [], fields: [:], startTime: startTime)
        }
        if let rows = response.json as? [[String: Any]] {
            return renderObjects(rows, startTime: startTime)
        }
        return renderRawJson(response, startTime: startTime)
    }

    // MARK: - Rendering

    private func renderHits(
        _ hits: [[String: Any]],
        mappingColumns: [ElasticsearchColumn],
        fields: [String: ElasticsearchFieldInfo],
        startTime: Date
    ) -> PluginQueryResult {
        let columns = ElasticsearchMappingFlattener.columns(forHits: hits, mappingColumns: mappingColumns)
        let rows = ElasticsearchMappingFlattener.rows(forHits: hits, columns: columns)
        let typeNames = columns.map { column -> String in
            switch column {
            case ElasticsearchMappingFlattener.idColumn, ElasticsearchMappingFlattener.indexColumn:
                return "keyword"
            case ElasticsearchMappingFlattener.scoreColumn:
                return "float"
            default:
                return fields[column]?.type ?? ""
            }
        }
        return PluginQueryResult(
            columns: columns,
            columnTypeNames: typeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func renderObjects(_ objects: [[String: Any]], startTime: Date) -> PluginQueryResult {
        let columns = ElasticsearchMappingFlattener.unionColumns(fromSources: objects)
        let rows = objects.map { object -> [PluginCellValue] in
            let flat = ElasticsearchMappingFlattener.flattenSource(object)
            return columns.map { flat[$0] ?? .null }
        }
        return PluginQueryResult(
            columns: columns.isEmpty ? ["response"] : columns,
            columnTypeNames: columns.isEmpty ? ["json"] : columns.map { _ in "" },
            rows: columns.isEmpty ? [] : rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func renderRawJson(_ response: ElasticsearchResponse, startTime: Date) -> PluginQueryResult {
        let pretty: String
        if let json = response.json,
           JSONSerialization.isValidJSONObject(json),
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            pretty = string
        } else {
            pretty = response.rawText
        }
        return PluginQueryResult(
            columns: ["response"],
            columnTypeNames: ["json"],
            rows: [[.text(pretty)]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Helpers

    static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "<unserializable>" }
        return string
    }

    private func extractHits(_ response: ElasticsearchResponse) -> [[String: Any]] {
        guard let json = response.json as? [String: Any],
              let hitsObject = json["hits"] as? [String: Any],
              let hits = hitsObject["hits"] as? [[String: Any]]
        else { return [] }
        return hits
    }

    private func mapWriteError(_ response: ElasticsearchResponse) -> ElasticsearchError {
        let reason = (response.json as? [String: Any]).flatMap { json -> String? in
            if let error = json["error"] as? [String: Any] {
                return [error["type"] as? String, error["reason"] as? String]
                    .compactMap { $0 }.joined(separator: ": ")
            }
            return json["error"] as? String
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return .authFailed(reason ?? "Access denied")
        }
        return .serverError(reason ?? "HTTP \(response.statusCode)")
    }
}
