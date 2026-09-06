//
//  TypesensePluginDriver+Execution.swift
//  TypesenseDriverPlugin
//
//  Query routing, search execution, and response rendering.
//

import Foundation
import TableProPluginKit

extension TypesensePluginDriver {
    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()
        let connection = try requireConnection()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased() == "select 1" {
            try await connection.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["int32"],
                rows: [[.text("1")]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        if TypesenseQueryBuilder.isTaggedQuery(trimmed) {
            return try await executeSearch(trimmed, connection: connection, startTime: startTime)
        }

        if TypesenseStatementGenerator.isTaggedStatement(trimmed) {
            return try await executeWrite(trimmed, connection: connection, startTime: startTime)
        }

        return try await executeConsole(trimmed, connection: connection, startTime: startTime)
    }

    // MARK: - Search

    private func executeSearch(
        _ query: String,
        connection: TypesenseConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let (base, appendedSorts) = TypesenseQueryBuilder.extractOrderBy(query)
        guard let parsedBase = TypesenseQueryBuilder.parseSearch(base) else {
            throw TypesenseError.invalidResponse("Invalid search request")
        }
        let parsed = appendedSorts.isEmpty ? parsedBase : parsedBase.replacingSorts(appendedSorts)

        let collection = try await cachedCollection(parsed.collection)
        let fields = collection.fieldsByName
        let filterBy = try TypesenseFilterBuilder.expression(
            filters: parsed.filters, logicMode: parsed.logicMode, fields: fields
        )
        let sortBy = TypesenseQueryBuilder.sortBy(parsed.sorts, fields: fields)

        Self.logger.debug("""
        executeSearch collection=\(parsed.collection, privacy: .public) \
        offset=\(parsed.offset) limit=\(parsed.limit) \
        filterBy=\(filterBy ?? "<none>", privacy: .public) sortBy=\(sortBy ?? "<none>", privacy: .public)
        """)

        let documents = try await fetchDocuments(
            parsed: parsed, filterBy: filterBy, sortBy: sortBy, connection: connection
        )
        return render(documents: documents, columns: collection.columns, fields: fields, startTime: startTime)
    }

    /// A page larger than 250 rows becomes several searches, and one `multi_search` carries up to
    /// 50 of them, so a 1,000-row page is a single round trip.
    private func fetchDocuments(
        parsed: TypesenseParsedSearch,
        filterBy: String?,
        sortBy: String?,
        connection: TypesenseConnection
    ) async throws -> [[String: Any]] {
        let chunks = TypesenseQueryBuilder.chunks(offset: parsed.offset, limit: parsed.limit)
        var documents: [[String: Any]] = []

        for batch in TypesenseQueryBuilder.batches(chunks) {
            try Task.checkCancellation()
            let searches = batch.map {
                TypesenseQueryBuilder.searchBody(
                    collection: parsed.collection, chunk: $0, filterBy: filterBy, sortBy: sortBy
                )
            }
            let results = try await connection.multiSearch(searches)
            var exhausted = results.count < batch.count
            for (chunk, result) in zip(batch, results) {
                let page = hits(in: result)
                documents += page
                if page.count < chunk.limit { exhausted = true }
            }
            if exhausted { break }
        }

        return documents
    }

    // MARK: - Streaming Export

    /// Export reads the collection's JSONL endpoint a line at a time, so a collection larger than
    /// memory still exports and the 250-hit search ceiling never applies. Anything that is not an
    /// export tag runs as an ordinary query and is handed over in one batch.
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    try await self.performStreamRows(query: query, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func performStreamRows(
        query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        guard let collection = TypesenseOperations.decodeExport(query) else {
            let result = try await execute(query: query)
            continuation.yield(.header(PluginStreamHeader(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                estimatedRowCount: nil
            )))
            if !result.rows.isEmpty { continuation.yield(.rows(result.rows)) }
            continuation.finish()
            return
        }

        let connection = try requireConnection()
        let schema = try await cachedCollection(collection)
        let columns = schema.columns
        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: TypesenseSchema.typeNames(for: columns, fields: schema.fieldsByName),
            estimatedRowCount: schema.numDocuments
        )))

        var batch: [[String: Any]] = []
        try await connection.streamExport(collection: collection) { document in
            batch.append(document)
            guard batch.count >= Self.exportBatchSize else { return true }
            continuation.yield(.rows(TypesenseSchema.rows(for: batch, columns: columns)))
            batch.removeAll(keepingCapacity: true)
            return true
        }
        if !batch.isEmpty {
            continuation.yield(.rows(TypesenseSchema.rows(for: batch, columns: columns)))
        }
        continuation.finish()
    }

    // MARK: - Write

    private func executeWrite(
        _ statement: String,
        connection: TypesenseConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard let request = TypesenseStatementGenerator.decode(statement) else {
            throw TypesenseError.invalidResponse("Invalid write request")
        }

        let response = try await connection.request(
            method: request.method, path: request.path, body: request.body
        )
        guard response.isSuccess else { throw connection.mapError(response, fallback: "Write failed") }

        let id = (response.json as? [String: Any])?[TypesenseSchema.idColumn] as? String
        return PluginQueryResult(
            columns: [TypesenseSchema.idColumn],
            columnTypeNames: ["string"],
            rows: [[TypesenseSchema.cell(id)]],
            rowsAffected: 1,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Console

    private func executeConsole(
        _ input: String,
        connection: TypesenseConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard let request = TypesenseConsoleParser.parse(input) else {
            throw TypesenseError.invalidResponse(
                String(localized: "Enter a request like: GET /collections")
            )
        }

        let response = try await connection.request(
            method: request.method, path: request.path, body: request.body
        )
        guard response.isSuccess else { throw connection.mapError(response, fallback: "Request failed") }

        if let result = searchResult(in: response.json) {
            let documents = hits(in: result)
            let columns = TypesenseSchema.unionColumns(fromDocuments: documents)
            return render(documents: documents, columns: columns, fields: [:], startTime: startTime)
        }
        if let objects = response.json as? [[String: Any]] {
            return render(
                documents: objects,
                columns: TypesenseSchema.unionColumns(fromDocuments: objects),
                fields: [:],
                startTime: startTime
            )
        }
        if let lines = jsonLines(in: response) {
            return render(
                documents: lines,
                columns: TypesenseSchema.unionColumns(fromDocuments: lines),
                fields: [:],
                startTime: startTime
            )
        }
        return renderRawJson(response, startTime: startTime)
    }

    // MARK: - Rendering

    private func render(
        documents: [[String: Any]],
        columns: [String],
        fields: [String: TypesenseField],
        startTime: Date
    ) -> PluginQueryResult {
        guard !columns.isEmpty else {
            return PluginQueryResult(
                columns: ["response"],
                columnTypeNames: ["json"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
        return PluginQueryResult(
            columns: columns,
            columnTypeNames: TypesenseSchema.typeNames(for: columns, fields: fields),
            rows: TypesenseSchema.rows(for: documents, columns: columns),
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func renderRawJson(_ response: TypesenseResponse, startTime: Date) -> PluginQueryResult {
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

    /// A search answers with `hits` at the top level. A `multi_search` wraps one such object per
    /// search, so a single-search body renders as a grid and a batch stays raw JSON, having no one
    /// result set to show.
    private func searchResult(in json: Any?) -> [String: Any]? {
        guard let object = json as? [String: Any] else { return nil }
        if object["hits"] is [[String: Any]] { return object }
        guard let results = object["results"] as? [[String: Any]], results.count == 1,
              results[0]["hits"] is [[String: Any]]
        else { return nil }
        return results[0]
    }

    private func hits(in result: [String: Any]) -> [[String: Any]] {
        guard let entries = result["hits"] as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["document"] as? [String: Any] }
    }

    /// `GET /collections/:c/documents/export` answers JSONL, which is not valid JSON as a whole.
    private func jsonLines(in response: TypesenseResponse) -> [[String: Any]]? {
        let lines = response.rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count > 1 else { return nil }

        var documents: [[String: Any]] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            documents.append(object)
        }
        return documents
    }
}
