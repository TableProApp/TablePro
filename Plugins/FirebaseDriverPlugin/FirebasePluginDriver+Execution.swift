import Foundation
import TableProFirebaseCore
import TableProPluginKit

extension FirebasePluginDriver {
    static let consolePageSize = 100
    static let exportPageSize = 500
    /// Export fixes its columns from the first page; a field that only later documents have goes
    /// here as JSON rather than being dropped.
    static let extraColumn = "__extra__"

    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "select 1" {
            try await ping()
            return PluginQueryResult(columns: ["ok"], columnTypeNames: ["integer"], rows: [[.text("1")]],
                                     rowsAffected: 0, executionTime: elapsed(since: started))
        }
        switch try FirebaseStatement.parse(trimmed) {
        case .browse(let spec):
            return try await browse(spec, started: started)
        case .request(let request):
            switch variant {
            case .firestore:
                return try await executeFirestore(request, started: started)
            case .realtimeDatabase:
                return try await executeRealtimeDatabase(request, started: started)
            }
        }
    }

    // MARK: - Browse

    func browse(_ spec: FirebaseBrowseSpec, started: Date = Date()) async throws -> PluginQueryResult {
        switch variant {
        case .firestore:
            return try await browseFirestore(spec, started: started)
        case .realtimeDatabase:
            return try await browseRealtimeDatabase(spec, started: started)
        }
    }

    private func browseFirestore(_ spec: FirebaseBrowseSpec, started: Date) async throws -> PluginQueryResult {
        let client = try requireFirestore()
        let target = try FirestoreCollectionTarget(table: spec.table)
        if !spec.filters.isEmpty, columnTypes(spec.table).isEmpty {
            _ = try await browseFirestore(FirebaseBrowseSpec(table: spec.table, limit: 20, offset: 0), started: started)
        }
        let types = columnTypes(spec.table)
        let body = try FirestoreQueryBuilder.structuredQuery(spec: spec, target: target, documentRoot: client.documentRoot,
                                                             typeOf: { types[$0] })
        let documents = try await client.runQuery(parent: target.parentPath, body: body,
                                                  operation: String(format: String(localized: "read %@"), spec.table))
        return firestoreResult(FirestoreRowSet(documents: documents, target: target), table: spec.table, started: started)
    }

    func firestoreResult(_ rows: FirestoreRowSet, table: String?, started: Date) -> PluginQueryResult {
        if let table {
            rememberColumnTypes(table, columns: rows.columns, types: rows.columnTypes)
        }
        rememberCellTypes(rows.cellTypes)
        var result = PluginQueryResult(
            columns: rows.columns,
            columnTypeNames: rows.columnTypes,
            rows: rows.rows.map { $0.map(Self.cell) },
            rowsAffected: 0,
            executionTime: elapsed(since: started)
        )
        result.rowLocators = rows.locators
        result.absentCells = rows.absentCells
        return result
    }

    private func browseRealtimeDatabase(_ spec: FirebaseBrowseSpec, started: Date) async throws -> PluginQueryResult {
        let client = try requireRealtimeDatabase()
        if !spec.filters.isEmpty, columnTypes(spec.table).isEmpty {
            _ = try await browseRealtimeDatabase(FirebaseBrowseSpec(table: spec.table, limit: 20, offset: 0), started: started)
        }
        let types = columnTypes(spec.table)
        let plan = try RealtimeDatabaseQueryPlanner.plan(spec: spec, typeOf: { types[$0] })
        let node = Self.nodePath(spec.table)
        let children = try await client.children(node, plan: plan)
        return databaseResult(RealtimeDatabaseRowSet(children: children, nodePath: node), table: spec.table, started: started)
    }

    func databaseResult(_ rows: RealtimeDatabaseRowSet, table: String?, started: Date) -> PluginQueryResult {
        if let table {
            rememberColumnTypes(table, columns: rows.columns, types: rows.columnTypes)
        }
        rememberCellTypes(rows.cellTypes)
        var result = PluginQueryResult(
            columns: rows.columns,
            columnTypeNames: rows.columnTypes,
            rows: rows.rows.map { $0.map(PluginCellValue.fromOptional) },
            rowsAffected: 0,
            executionTime: elapsed(since: started)
        )
        result.rowLocators = rows.locators
        result.absentCells = rows.absentCells
        return result
    }

    static func cell(_ display: FirestoreCell.Display) -> PluginCellValue {
        switch display {
        case .null: return .null
        case .text(let text): return .text(text)
        case .bytes(let data): return .bytes(data)
        }
    }

    // MARK: - Console: Firestore

    private func executeFirestore(_ request: FirebaseRequest, started: Date) async throws -> PluginQueryResult {
        let client = try requireFirestore()
        switch request.method {
        case .get:
            return try await firestoreGet(request, client: client, started: started)
        case .query:
            let body = try FirebaseJSON.parse(request.body ?? "")
            guard body["structuredQuery"] != nil else {
                throw FirebaseError.configuration(String(localized: "QUERY needs a JSON body with a structuredQuery."))
            }
            let documents = try await client.runQuery(parent: request.path, body: body, operation: "QUERY")
            return firestoreResult(FirestoreRowSet(documents: documents, target: try Self.pathTarget(documents)), table: nil, started: started)
        case .post:
            let fields = try FirestoreDocumentJSON.fields(from: request.body ?? "")
            let created = try await client.createDocument(collectionPath: request.path, documentId: request.queryValue("documentId"), fields: fields)
            return writeResult(created.path, started: started)
        case .patch:
            guard FirestorePath.isDocument(request.path) else {
                throw FirebaseError.configuration(String(localized: "PATCH needs a document path, such as users/alice."))
            }
            let fields = try FirestoreDocumentJSON.fields(from: request.body ?? "")
            let mask = request.queryValue("updateMask").map { text in
                text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            try await client.patchDocument(request.path, fields: fields, mask: mask)
            return writeResult(request.path, started: started)
        case .delete:
            guard FirestorePath.isDocument(request.path) else {
                throw FirebaseError.configuration(String(localized: "DELETE needs a document path, such as users/alice."))
            }
            try await client.deleteDocument(request.path)
            return writeResult(request.path, started: started)
        case .put:
            throw FirebaseError.unsupported(String(localized: "Firestore has no PUT. Use POST to create a document and PATCH to change one."))
        }
    }

    private func firestoreGet(_ request: FirebaseRequest, client: FirestoreClient, started: Date) async throws -> PluginQueryResult {
        let listsCollections = request.path.isEmpty
            || (FirestorePath.isDocument(request.path) && request.queryValue("collections") != nil)
        if listsCollections {
            let ids = try await client.listCollectionIds(parent: request.path)
            return PluginQueryResult(columns: ["collection"], columnTypeNames: ["string"], rows: ids.map { [.text($0)] },
                                     rowsAffected: 0, executionTime: elapsed(since: started))
        }
        if FirestorePath.isDocument(request.path) {
            guard let document = try await client.getDocument(request.path) else {
                throw FirebaseError.notFound(String(format: String(localized: "No document at %@."), request.path))
            }
            let target = try FirestoreCollectionTarget(table: FirestorePath.split(collectionPath: request.path).parent)
            return firestoreResult(FirestoreRowSet(documents: [document], target: target), table: nil, started: started)
        }
        let limit = request.queryValue("pageSize").flatMap(Int.init) ?? Self.consolePageSize
        let spec = FirebaseBrowseSpec(table: request.path, limit: limit, offset: 0)
        return try await browseFirestore(spec, started: started)
    }

    /// A console query can span parents, so its rows are named by full path.
    private static func pathTarget(_ documents: [FirestoreDocument]) throws -> FirestoreCollectionTarget {
        let id = documents.first.map { FirestorePath.split(collectionPath: FirestorePath.split(collectionPath: $0.path).parent).collectionId }
        return try FirestoreCollectionTarget(table: FirestoreCollectionTarget.groupName(id ?? "documents"))
    }

    // MARK: - Console: Realtime Database

    private func executeRealtimeDatabase(_ request: FirebaseRequest, started: Date) async throws -> PluginQueryResult {
        let client = try requireRealtimeDatabase()
        switch request.method {
        case .get:
            let json = try await client.get(request.path, query: request.query)
            if case .object(let members) = json {
                let children = members.map { (key: $0.key, value: $0.value) }
                    .sorted { RealtimeDatabaseOrdering.keyPrecedes($0.key, $1.key) }
                return databaseResult(RealtimeDatabaseRowSet(children: children, nodePath: request.path), table: nil, started: started)
            }
            return databaseResult(RealtimeDatabaseRowSet(children: json == .null ? [] : [("", json)], nodePath: request.path),
                                  table: nil, started: started)
        case .put:
            try await client.put(request.path, value: try FirebaseJSON.parse(request.body ?? ""))
            return writeResult("/" + request.path, started: started)
        case .patch:
            guard case .object(let values) = try FirebaseJSON.parse(request.body ?? "") else {
                throw FirebaseError.configuration(String(localized: "PATCH needs a JSON object of the children to change."))
            }
            try await client.patch(request.path, values: values)
            return writeResult("/" + request.path, started: started)
        case .post:
            let key = try await client.push(request.path, value: try FirebaseJSON.parse(request.body ?? ""))
            return writeResult(RealtimeDatabasePath.join("/" + request.path, key ?? ""), started: started)
        case .delete:
            guard !request.path.isEmpty else {
                throw FirebaseError.unsupported(String(localized: "Deleting the whole database is not offered. Delete its children one at a time."))
            }
            try await client.delete(request.path)
            return writeResult("/" + request.path, started: started)
        case .query:
            throw FirebaseError.unsupported(String(localized: "QUERY is for Firestore. Use GET with orderBy, equalTo, startAt or limitToFirst."))
        }
    }

    private func writeResult(_ path: String, started: Date) -> PluginQueryResult {
        PluginQueryResult(columns: ["path"], columnTypeNames: ["string"], rows: [[.text(path)]],
                          rowsAffected: 1, executionTime: elapsed(since: started))
    }

    // MARK: - Export

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    if case .browse(let spec)? = try? FirebaseStatement.parse(query), spec.limit == 0 {
                        try await self.export(spec, continuation: continuation)
                    } else {
                        let result = try await self.execute(query: query)
                        continuation.yield(.header(PluginStreamHeader(columns: result.columns, columnTypeNames: result.columnTypeNames,
                                                                      estimatedRowCount: nil)))
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

    private func export(_ spec: FirebaseBrowseSpec, continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation) async throws {
        var header: [String]?
        var types: [String] = []
        try await forEachExportPage(spec) { columns, columnTypes, rows in
            if header == nil {
                header = columns + [Self.extraColumn]
                types = columnTypes + ["map"]
                continuation.yield(.header(PluginStreamHeader(columns: header ?? [], columnTypeNames: types, estimatedRowCount: nil)))
            }
            let fixed = header ?? []
            continuation.yield(.rows(rows.map { row in Self.align(row, columns: columns, to: fixed) }))
        }
        if header == nil {
            continuation.yield(.header(PluginStreamHeader(columns: [Self.extraColumn], columnTypeNames: ["map"], estimatedRowCount: nil)))
        }
    }

    /// Places a page's cells under the export's columns and gathers the rest into `__extra__`.
    static func align(_ row: [PluginCellValue], columns: [String], to header: [String]) -> [PluginCellValue] {
        var byName: [String: PluginCellValue] = [:]
        for (column, value) in zip(columns, row) { byName[column] = value }
        var aligned = header.dropLast().map { byName.removeValue(forKey: $0) ?? .null }
        let extra = byName.filter { !$0.value.isNull }.mapValues { FirebaseJSON.string($0.asText ?? $0.sortKey) }
        aligned.append(extra.isEmpty ? .null : .text(FirebaseJSON.object(extra).text()))
        return aligned
    }

    private func forEachExportPage(
        _ spec: FirebaseBrowseSpec,
        page: ([String], [String], [[PluginCellValue]]) throws -> Void
    ) async throws {
        switch variant {
        case .firestore:
            let client = try requireFirestore()
            let target = try FirestoreCollectionTarget(table: spec.table)
            let types = columnTypes(spec.table)
            var cursor: String?
            repeat {
                try Task.checkCancellation()
                let pageSpec = FirebaseBrowseSpec(table: spec.table, filters: spec.filters, logicMode: spec.logicMode,
                                                  sorts: [FirebaseSortSpec(column: FirestoreQueryBuilder.nameField, ascending: true)],
                                                  limit: Self.exportPageSize, offset: 0)
                var body = try FirestoreQueryBuilder.structuredQuery(spec: pageSpec, target: target, documentRoot: client.documentRoot,
                                                                     typeOf: { types[$0] })
                if let cursor, case .object(var outer) = body, case .object(var query)? = outer["structuredQuery"] {
                    query["startAt"] = .object([
                        "values": .array([.object(["referenceValue": .string(FirestorePath.absolute(cursor, documentRoot: client.documentRoot))])]),
                        "before": .bool(false)
                    ])
                    outer["structuredQuery"] = .object(query)
                    body = .object(outer)
                }
                let documents = try await client.runQuery(parent: target.parentPath, body: body,
                                                          operation: String(format: String(localized: "export %@"), spec.table))
                guard !documents.isEmpty else { return }
                let rows = FirestoreRowSet(documents: documents, target: target)
                try page(rows.columns, rows.columnTypes, rows.rows.map { $0.map(Self.cell) })
                cursor = documents.count == Self.exportPageSize ? documents.last?.path : nil
            } while cursor != nil
        case .realtimeDatabase:
            guard spec.filters.isEmpty else {
                let result = try await browse(spec)
                try page(result.columns, result.columnTypeNames, result.rows)
                return
            }
            let client = try requireRealtimeDatabase()
            let node = Self.nodePath(spec.table)
            var lastKey: String?
            repeat {
                try Task.checkCancellation()
                var bounds: [String: String] = [:]
                if let lastKey { bounds["startAfter"] = FirebaseJSON.string(lastKey).text() }
                let plan = RealtimeDatabaseReadPlan(order: .key, ascending: true, bounds: bounds,
                                                    fetchCount: Self.exportPageSize, dropCount: 0, rawQuery: nil)
                let children = try await client.children(node, plan: plan)
                guard !children.isEmpty else { return }
                let rows = RealtimeDatabaseRowSet(children: children, nodePath: node)
                try page(rows.columns, rows.columnTypes, rows.rows.map { $0.map(PluginCellValue.fromOptional) })
                lastKey = children.count == Self.exportPageSize ? children.last?.key : nil
            } while lastKey != nil
        }
    }
}
