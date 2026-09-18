import Foundation
import TableProPluginKit
import TableProWeaviateCore

extension WeaviatePluginDriver {
    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let client = try requireClient()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased() == "select 1" {
            try await client.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["int"],
                rows: [[.text("1")]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(started)
            )
        }

        if WeaviateBrowseQuery.isTagged(trimmed) {
            return try await executeSearch(trimmed, client: client, started: started)
        }
        if WeaviateWriteCodec.isTagged(trimmed) {
            return try await executeWrite(trimmed, client: client, started: started)
        }
        if let console = WeaviateConsoleParser.parse(trimmed) {
            return try await executeConsole(console, client: client, started: started)
        }
        if WeaviateGraphQL.looksLikeGraphQL(trimmed) {
            return try await executeGraphQL(trimmed, client: client, started: started)
        }

        throw WeaviateError.malformedResponse(
            String(localized: "Enter a GraphQL query, or a request like GET /v1/schema.")
        )
    }

    // MARK: - Export

    static let exportPageSize = 500

    /// Exports one collection by walking it a page at a time, yielding each page instead of
    /// holding the whole collection. The protocol default runs `execute` once and buffers
    /// everything, which is fine for a grid page and not for an export.
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let collectionName = WeaviateOperations.decodeExport(query) else {
            return defaultStreamRows(query: query)
        }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    try await self.streamCollection(collectionName, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func streamCollection(
        _ name: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let client = try requireClient()
        let collection = try await cachedCollection(name)
        let columns = WeaviateSchema.columns(for: collection).map(\.name)
        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columns.map { typeName(for: $0, collection: collection) },
            estimatedRowCount: nil
        )))

        var offset = 0
        while true {
            try Task.checkCancellation()
            let objects = try await client.objects(
                collection: name, limit: Self.exportPageSize, offset: offset, includeVector: true
            )
            guard !objects.isEmpty else { break }
            continuation.yield(.rows(objects.map { object in
                WeaviateObjectCodec.row(for: object, columns: columns).map { value in
                    value.map(PluginCellValue.text) ?? .null
                }
            }))
            if objects.count < Self.exportPageSize { break }
            offset += objects.count
        }
    }

    private func defaultStreamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let result = try await self.execute(query: query)
                    continuation.yield(.header(PluginStreamHeader(
                        columns: result.columns,
                        columnTypeNames: result.columnTypeNames,
                        estimatedRowCount: nil
                    )))
                    if !result.rows.isEmpty { continuation.yield(.rows(result.rows)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func executeSearch(
        _ query: String,
        client: WeaviateClient,
        started: Date
    ) async throws -> PluginQueryResult {
        guard let parsed = WeaviateBrowseQuery.parse(query) else {
            throw WeaviateError.malformedResponse(String(localized: "Invalid browse request."))
        }
        let collection = try await cachedCollection(parsed.collection)
        let wantsVector = parsed.propertyNames.isEmpty
            || parsed.propertyNames.contains(WeaviateSchema.vectorColumn)
        let objects: [WeaviateObject]
        if parsed.usesGraphQL {
            let graphql = try WeaviateGraphQL.getQuery(
                collection: parsed.collection,
                properties: parsed.propertyNames,
                limit: parsed.limit,
                offset: parsed.offset,
                sorts: parsed.sortableSorts,
                filters: parsed.filters,
                logicMode: parsed.logicMode,
                schema: propertySchema(of: collection),
                includeVector: wantsVector
            )
            let response = try await client.graphql(graphql)
            objects = WeaviateObjectCodec.objects(fromGraphQL: response.json as Any)
        } else {
            objects = try await client.objects(
                collection: parsed.collection,
                limit: parsed.limit,
                offset: parsed.offset,
                includeVector: wantsVector
            )
        }
        return render(objects: objects, collection: collection, columns: parsed.propertyNames, started: started)
    }

    private func executeWrite(
        _ statement: String,
        client: WeaviateClient,
        started: Date
    ) async throws -> PluginQueryResult {
        guard let request = WeaviateWriteCodec.decode(statement) else {
            throw WeaviateError.malformedResponse(String(localized: "Invalid write request."))
        }
        let response = try await client.execute(write: request)
        let outcome: String
        if let json = WeaviateJSON.dictionary(response.json), let id = json["id"] as? String {
            outcome = id
        } else if response.statusCode == 204 {
            outcome = "deleted"
        } else {
            outcome = "ok"
        }
        return PluginQueryResult(
            columns: ["result"],
            columnTypeNames: ["text"],
            rows: [[.text(outcome)]],
            rowsAffected: 1,
            executionTime: Date().timeIntervalSince(started)
        )
    }

    private func executeConsole(
        _ request: WeaviateConsoleRequest,
        client: WeaviateClient,
        started: Date
    ) async throws -> PluginQueryResult {
        if request.method == "POST", request.path.hasPrefix("/v1/graphql"), let body = request.body {
            return try await executeGraphQL(body, client: client, started: started)
        }
        let response = try await client.execute(console: request)
        if request.path.hasPrefix("/v1/objects"), let json = response.json {
            let objects = WeaviateObject.parseList(json)
            if !objects.isEmpty {
                return await renderReturnedColumns(objects, started: started)
            }
        }
        return renderJSON(response, started: started)
    }

    private func executeGraphQL(
        _ query: String,
        client: WeaviateClient,
        started: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.graphql(query)
        let objects = WeaviateObjectCodec.objects(fromGraphQL: response.json as Any)
        if !objects.isEmpty {
            return await renderReturnedColumns(objects, started: started)
        }
        return renderJSON(response, started: started)
    }

    /// A console query selects its own fields, so the result shows what came back rather than every
    /// column the collection has. That is also what carries `_additional { distance }` into the grid.
    private func renderReturnedColumns(_ objects: [WeaviateObject], started: Date) async -> PluginQueryResult {
        let collectionName = objects.first?.className ?? ""
        let collection = (try? await cachedCollection(collectionName))
            ?? WeaviateCollection(name: collectionName, properties: [])
        return render(
            objects: objects,
            collection: collection,
            columns: returnedColumns(of: objects, collection: collection),
            started: started
        )
    }

    private func returnedColumns(of objects: [WeaviateObject], collection: WeaviateCollection) -> [String] {
        let declared = collection.properties.map(\.name)
        let returned = Set(objects.flatMap { $0.properties.keys })
        var columns: [String] = []
        if objects.contains(where: { !$0.uuid.isEmpty }) {
            columns.append(WeaviateSchema.uuidColumn)
        }
        columns += declared.filter { returned.contains($0) }
        columns += returned.subtracting(declared).sorted()
        if objects.contains(where: { $0.vector != nil }) {
            columns.append(WeaviateSchema.vectorColumn)
        }
        return columns.isEmpty ? [WeaviateSchema.uuidColumn] : columns
    }

    private func render(
        objects: [WeaviateObject],
        collection: WeaviateCollection,
        columns: [String],
        started: Date
    ) -> PluginQueryResult {
        let resolved = columns.isEmpty
            ? WeaviateSchema.columns(for: collection).map(\.name)
            : columns
        let rows = objects.map { object in
            WeaviateObjectCodec.row(for: object, columns: resolved).map { value in
                value.map(PluginCellValue.text) ?? .null
            }
        }
        return PluginQueryResult(
            columns: resolved,
            columnTypeNames: resolved.map { typeName(for: $0, collection: collection) },
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(started)
        )
    }

    private func renderJSON(_ response: WeaviateHTTPResponse, started: Date) -> PluginQueryResult {
        let pretty: String
        if let json = response.json, JSONSerialization.isValidJSONObject(json),
           let text = try? WeaviateJSON.text(json, pretty: true) {
            pretty = text
        } else {
            pretty = response.text
        }
        return PluginQueryResult(
            columns: ["response"],
            columnTypeNames: ["json"],
            rows: [[.text(pretty)]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(started)
        )
    }
}
