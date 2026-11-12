//
//  CassandraPluginDriver+Browse.swift
//  CassandraDriverPlugin
//

import Foundation
import os
import TableProCassandraCore
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.CassandraDriver", category: "Browse")

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
            count.cql,
            parameters: count.values.map { .text($0) },
            consistency: sessionConsistency,
            cancellation: cancellation
        )
        return result.rows.first?.first?.asText.flatMap { Int($0) }
    }

    func cancelQuery() throws {
        activeBrowse.cancel()
    }

    func runBrowse(
        _ browse: CassandraBrowseStatement,
        consistency: CassandraConsistency?,
        rowCap: Int? = nil,
        consumerLeft: @escaping @Sendable () -> Bool = { false }
    ) async throws -> PluginQueryResult {
        let cancellation = activeBrowse.begin(consumerLeft: consumerLeft)
        defer { activeBrowse.end(cancellation) }
        let capture = try await lifetimeCapture(for: browse, cancellation: cancellation)
        // Taken before the request, so the time a kept TTL has run counts the whole request.
        let readAt = ContinuousClock.now
        let run = try await connectionActor.executeBrowse(
            capture.map { browse.sending($0.plan.cql) } ?? browse,
            fallback: capture == nil ? nil : browse,
            consistency: consistency,
            cancellation: cancellation
        )
        var raw = run.result
        if let capture, !run.ranFallback {
            raw = keepLifetimes(of: raw, capture: capture, readAt: readAt)
        }
        let isTruncated = rowCap.map { raw.rows.count > $0 } ?? false
        let rows = isTruncated ? Array(raw.rows.prefix(rowCap ?? raw.rows.count)) : raw.rows
        return PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: rows,
            rowsAffected: rows.count,
            executionTime: raw.executionTime,
            isTruncated: isTruncated,
            statusMessage: consistency?.statusMessage(columns: raw.columns)
        )
    }

    func streamBrowse(
        _ browse: CassandraBrowseStatement,
        consistency: CassandraConsistency?
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginRowStream.make { continuation, abort in
            let streamTask = Task {
                do {
                    let result = try await self.runBrowse(
                        browse, consistency: consistency, consumerLeft: { abort.isAborted }
                    )
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

    private struct LifetimeCapture: Sendable {
        let plan: CassandraLifetimeRead.Plan
        let table: CassandraTableIdentity
        let layout: CassandraTableLayout
    }

    // A browse from the first row reads the table's columns again, so a column added since is shown. A read larger
    // than the store holds, such as a copy or an export, runs as written.
    private func lifetimeCapture(
        for browse: CassandraBrowseStatement,
        cancellation: CassandraCancellation
    ) async throws -> LifetimeCapture? {
        let window = browse.window
        guard window.refusal == nil, window.limit <= CassandraCellLifetimeStore.maximumRows,
              let tableName = window.table,
              let keyspace = window.keyspace.flatMap({ $0.isEmpty ? nil : $0 }) ?? currentSchema
        else { return nil }
        let table = CassandraTableIdentity(keyspace: keyspace, table: tableName)
        guard let layout = try await tableLayout(table, refresh: window.offset == 0, cancellation: cancellation),
              let plan = CassandraLifetimeRead.plan(
                  cql: browse.cql,
                  target: CassandraBrowseRenderer.qualifiedTable(keyspace: window.keyspace, table: tableName),
                  layout: layout
              )
        else { return nil }
        return LifetimeCapture(plan: plan, table: table, layout: layout)
    }

    private func tableLayout(
        _ table: CassandraTableIdentity,
        refresh: Bool,
        cancellation: CassandraCancellation
    ) async throws -> CassandraTableLayout? {
        if !refresh, let known = cellLifetimes.layout(of: table) { return known.layout }
        let columns: CassandraRawResult
        let options: CassandraRawResult
        do {
            columns = try await connectionActor.executeQuery(
                CassandraTableLayout.columnsQuery(keyspace: table.keyspace, table: table.table),
                consistency: nil,
                cancellation: cancellation
            )
            options = try await connectionActor.executeQuery(
                CassandraTableLayout.defaultTimeToLiveQuery(keyspace: table.keyspace, table: table.table),
                consistency: nil,
                cancellation: cancellation
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            logger.info("Browse runs without TTL selectors, the table's columns were not read: \(error.localizedDescription)")
            return nil
        }
        let layout = Self.layout(columns: columns.rows, options: options.rows)
        cellLifetimes.setLayout(layout, of: table)
        return layout
    }

    private static func layout(columns: [[PluginCellValue]], options: [[PluginCellValue]]) -> CassandraTableLayout? {
        var parsed: [CassandraTableLayout.Column] = []
        for row in columns {
            guard let column = CassandraTableLayout.column(
                name: row[safe: 0]?.asText,
                type: row[safe: 1]?.asText,
                kind: row[safe: 2]?.asText,
                position: row[safe: 3]?.asText
            ) else { return nil }
            parsed.append(column)
        }
        let defaultTimeToLive = options.first?[safe: 0]?.asText.flatMap { Int($0) }
        return CassandraTableLayout(columns: parsed, defaultTimeToLive: defaultTimeToLive)
    }

    // The host sees the columns it asked for. Every row read replaces what was kept for its key, or drops it.
    private func keepLifetimes(
        of raw: CassandraRawResult,
        capture: LifetimeCapture,
        readAt: ContinuousClock.Instant
    ) -> CassandraRawResult {
        let plan = capture.plan
        let shownCount = plan.shownColumns.count
        guard raw.columns.count == shownCount + plan.lifetimeColumns.count else { return raw }
        var read: [(row: CassandraRowIdentity, lifetimes: CassandraRowLifetimes?)] = []
        read.reserveCapacity(raw.rows.count)
        let rows = raw.rows.map { row -> [PluginCellValue] in
            if let key = Self.key(of: row, plan: plan) {
                read.append((
                    CassandraRowIdentity(table: capture.table, key: key),
                    Self.lifetimes(of: row, capture: capture, readAt: readAt)
                ))
            }
            return Array(row.prefix(shownCount))
        }
        cellLifetimes.keep(read)
        return CassandraRawResult(
            columns: Array(raw.columns.prefix(shownCount)),
            columnTypeNames: Array(raw.columnTypeNames.prefix(shownCount)),
            rows: rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime
        )
    }

    private static func key(of row: [PluginCellValue], plan: CassandraLifetimeRead.Plan) -> [String: PluginCellValue]? {
        var key: [String: PluginCellValue] = [:]
        for (column, index) in plan.keyIndices {
            guard index < row.count, !row[index].isNull else { return nil }
            key[column] = row[index]
        }
        return key
    }

    private static func lifetimes(
        of row: [PluginCellValue],
        capture: LifetimeCapture,
        readAt: ContinuousClock.Instant
    ) -> CassandraRowLifetimes? {
        let plan = capture.plan
        let lifetimes = plan.lifetimeValueIndices.enumerated().map { selector, valueIndex -> CassandraCellLifetime? in
            let timeToLiveIndex = plan.shownColumns.count + selector
            guard valueIndex < row.count, timeToLiveIndex < row.count else { return nil }
            return CassandraCellLifetime(valueIsNull: row[valueIndex].isNull, timeToLive: row[timeToLiveIndex].asText)
        }
        return CassandraRowLifetimes(
            columns: plan.lifetimeColumns, lifetimes: lifetimes, readAt: readAt, layout: capture.layout
        )
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

struct CassandraTableIdentity: Hashable, Sendable {
    let keyspace: String
    let table: String
}

struct CassandraRowIdentity: Hashable, Sendable {
    let table: CassandraTableIdentity
    let key: [String: PluginCellValue]
}

// What the browses on one connection read about cell lifetimes, so a later edit or restore writes each cell with
// the TTL it had left. Rows read longest ago drop out first.
final class CassandraCellLifetimeStore: @unchecked Sendable {
    static let maximumRows = 20_000
    static let maximumTables = 64

    // A table system_schema lists no layout for is remembered too, so its browse pages ask once.
    struct KnownLayout: Sendable {
        let layout: CassandraTableLayout?
    }

    private let lock = NSLock()
    private var rows = CassandraRecentEntries<CassandraRowIdentity, CassandraRowLifetimes>(
        capacity: CassandraCellLifetimeStore.maximumRows
    )
    private var layouts = CassandraRecentEntries<CassandraTableIdentity, KnownLayout>(
        capacity: CassandraCellLifetimeStore.maximumTables
    )

    func layout(of table: CassandraTableIdentity) -> KnownLayout? {
        lock.withLock { layouts[table] }
    }

    func setLayout(_ layout: CassandraTableLayout?, of table: CassandraTableIdentity) {
        lock.withLock { layouts.set(KnownLayout(layout: layout), for: table) }
    }

    func keep(_ read: [(row: CassandraRowIdentity, lifetimes: CassandraRowLifetimes?)]) {
        lock.withLock {
            for entry in read {
                if let lifetimes = entry.lifetimes {
                    rows.set(lifetimes, for: entry.row)
                } else {
                    rows.removeValue(for: entry.row)
                }
            }
        }
    }

    func lifetimes(of row: CassandraRowIdentity) -> CassandraRowLifetimes? {
        lock.withLock { rows[row] }
    }

    func removeAll() {
        lock.withLock {
            rows.removeAll()
            layouts.removeAll()
        }
    }
}
