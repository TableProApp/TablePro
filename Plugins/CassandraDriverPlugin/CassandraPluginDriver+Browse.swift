//
//  CassandraPluginDriver+Browse.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

extension CassandraPluginDriver {
    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table, schema: nil, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        CassandraBrowseRenderer.browse(
            keyspace: schema, table: table, columns: columns, filters: [], matchAll: true,
            sorted: !sortColumns.isEmpty, limit: limit, offset: offset
        ).text
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: nil, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: schema, queryFilters: filters.map(Self.queryFilter), logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset, columnKinds: [:]
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        CassandraBrowseRenderer.browse(
            keyspace: schema, table: table, columns: columns, filters: queryFilters,
            matchAll: Self.matchesAll(logicMode), sorted: !sortColumns.isEmpty, limit: limit, offset: offset
        ).text
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) async throws -> Int? {
        try await fetchExactRowCount(
            table: table, schema: schema, queryFilters: filters.map(Self.queryFilter), logicMode: logicMode
        )
    }

    /// Cassandra has no count cheaper than reading every partition, so this runs only when the user asks.
    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        let count = try CassandraBrowseRenderer.count(
            keyspace: schema, table: table, filters: queryFilters, matchAll: Self.matchesAll(logicMode)
        )
        let cancellation = activeBrowse.begin()
        defer { activeBrowse.end(cancellation) }
        let result = try await connectionActor.executePrepared(
            count.cql, parameters: count.values.map { .text($0) }, cancellation: cancellation
        )
        return result.rows.first?.first?.asText.flatMap { Int($0) }
    }

    func cancelQuery() throws {
        activeBrowse.cancel()
    }

    func runBrowse(
        _ browse: CassandraBrowseStatement,
        rowCap: Int? = nil,
        consumerLeft: @escaping @Sendable () -> Bool = { false }
    ) async throws -> PluginQueryResult {
        let cancellation = activeBrowse.begin(consumerLeft: consumerLeft)
        defer { activeBrowse.end(cancellation) }
        let raw = try await connectionActor.executeBrowse(browse, cancellation: cancellation)
        let isTruncated = rowCap.map { raw.rows.count > $0 } ?? false
        let rows = isTruncated ? Array(raw.rows.prefix(rowCap ?? raw.rows.count)) : raw.rows
        return PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: rows,
            rowsAffected: rows.count,
            executionTime: raw.executionTime,
            isTruncated: isTruncated
        )
    }

    func streamBrowse(_ browse: CassandraBrowseStatement) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginRowStream.make { continuation, abort in
            let streamTask = Task {
                do {
                    let result = try await self.runBrowse(browse, consumerLeft: { abort.isAborted })
                    continuation.yield(.header(PluginStreamHeader(
                        columns: result.columns,
                        columnTypeNames: result.columnTypeNames,
                        estimatedRowCount: result.rows.count
                    )))
                    if !result.rows.isEmpty {
                        continuation.yield(.rows(result.rows))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            _ = streamTask
        }
    }

    private static func matchesAll(_ logicMode: String) -> Bool {
        logicMode.lowercased() != "or"
    }

    private static func queryFilter(_ filter: (column: String, op: String, value: String)) -> PluginQueryFilter {
        PluginQueryFilter(column: filter.column, op: filter.op, value: filter.value, secondValue: nil, elementScope: nil)
    }
}

/// The browse walk that Stop reaches. Only one runs at a time on a connection, since its actor is serial.
final class CassandraActiveBrowse: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CassandraCancellation?

    func begin(consumerLeft: @escaping @Sendable () -> Bool = { false }) -> CassandraCancellation {
        let cancellation = CassandraCancellation(consumerLeft: consumerLeft)
        lock.lock()
        current = cancellation
        lock.unlock()
        return cancellation
    }

    func end(_ cancellation: CassandraCancellation) {
        lock.lock()
        if current === cancellation {
            current = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let running = current
        lock.unlock()
        running?.cancel()
    }
}
