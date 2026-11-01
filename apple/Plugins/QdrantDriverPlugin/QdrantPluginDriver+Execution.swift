import Foundation
import TableProPluginKit
import TableProQdrantCore

extension QdrantPluginDriver {
    static let exportPageSize = 500

    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let client = try requireClient()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased() == "select 1" {
            try await client.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["integer"],
                rows: [[.text("1")]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(started)
            )
        }
        if let request = QdrantBrowseQuery.parse(trimmed) {
            return try await executeBrowse(request, client: client, started: started)
        }
        if let request = QdrantConsoleParser.parse(trimmed) {
            return try await executeConsole(request, client: client, started: started)
        }
        throw QdrantError.malformedResponse(
            String(localized: "Enter a request like GET /collections or POST /collections/docs/points/query.")
        )
    }

    private func executeBrowse(
        _ request: QdrantBrowseRequest,
        client: QdrantClient,
        started: Date
    ) async throws -> PluginQueryResult {
        let collection = try await collection(request.collection)
        let filter = try QdrantFilterBuilder.filter(request.filters, logicMode: request.logicMode, collection: collection)
        let points: [QdrantPoint]
        if let sort = request.sort {
            points = try await client.query(
                collection: request.collection,
                body: QdrantBrowseQuery.queryBody(for: request, filter: filter, sort: sort)
            )
        } else {
            points = try await client.scrollPage(
                collection: request.collection,
                filter: filter,
                offset: request.offset,
                limit: request.limit,
                cache: cursors
            )
        }
        let columns = QdrantSchema.columns(for: collection).map(\.name)
        return render(points, columns: columns, collection: collection, started: started)
    }

    private func executeConsole(
        _ request: QdrantConsoleRequest,
        client: QdrantClient,
        started: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.execute(request)
        if !request.isRead {
            forgetAfterWrite()
        }
        if let points = QdrantPoint.list(fromResponse: response.json), !points.isEmpty {
            let name = Self.collectionName(in: request.path)
            let collection = name.flatMap(rememberedCollection)
            let columns = QdrantPoint.columns(of: points, collection: collection)
            return render(
                points,
                columns: columns,
                collection: collection ?? QdrantCollection(name: name ?? "", vectors: [], payloadFields: []),
                started: started
            )
        }
        return renderJSON(response, started: started)
    }

    static func collectionName(in path: String) -> String? {
        let segments = path.split(separator: "?").first?.split(separator: "/") ?? []
        guard segments.count >= 2, segments[0] == "collections" else { return nil }
        return String(segments[1]).removingPercentEncoding
    }

    private func render(
        _ points: [QdrantPoint],
        columns: [String],
        collection: QdrantCollection,
        started: Date
    ) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns,
            columnTypeNames: columns.map { QdrantSchema.typeName(of: $0, in: collection) },
            rows: points.map { point in point.row(columns: columns).map { $0.map(PluginCellValue.text) ?? .null } },
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(started)
        )
    }

    private func renderJSON(_ response: QdrantHTTPResponse, started: Date) -> PluginQueryResult {
        let text: String
        if let json = response.json, JSONSerialization.isValidJSONObject(json),
           let pretty = try? QdrantJSON.text(json, pretty: true) {
            text = pretty
        } else {
            text = response.text
        }
        return PluginQueryResult(
            columns: ["response"],
            columnTypeNames: ["json"],
            rows: [[.text(text)]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Export

    /// Walks the collection a page at a time instead of buffering it whole, which the protocol's
    /// default `streamRows` would do by running `execute` once.
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    if let name = QdrantOperations.decodeExport(query) {
                        try await self.streamCollection(name, continuation: continuation)
                    } else {
                        let result = try await self.execute(query: query)
                        continuation.yield(.header(PluginStreamHeader(
                            columns: result.columns,
                            columnTypeNames: result.columnTypeNames,
                            estimatedRowCount: nil
                        )))
                        if !result.rows.isEmpty { continuation.yield(.rows(result.rows)) }
                    }
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
        var collection = try await collection(name, refresh: true)
        // The grid's columns come from a sample; an export has to carry every key, so it reads
        // payloads alone first, which skips the vectors that make up most of a page.
        for try await points in client.pointPages(collection: name, pageSize: Self.exportPageSize, withVector: false) {
            collection = collection.including(points)
        }
        let columns = QdrantSchema.columns(for: collection).map(\.name)
        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columns.map { QdrantSchema.typeName(of: $0, in: collection) },
            estimatedRowCount: collection.pointsCount
        )))
        for try await points in client.pointPages(collection: name, pageSize: Self.exportPageSize) {
            continuation.yield(.rows(points.map { point in
                point.row(columns: columns).map { $0.map(PluginCellValue.text) ?? .null }
            }))
        }
    }
}
