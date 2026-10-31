//
//  TableHealthProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Reads one engine's catalogs into table and index health findings. Every query only reads;
/// the fixes it builds are text for the user to review.
protocol TableHealthProvider: Sendable {
    var checks: [TableHealthCheckKind] { get }
    /// MySQL calls a database a schema, so a finding's schema is the database its table opens in.
    var schemaNamesDatabase: Bool { get }
    var statisticsQueries: [String] { get }
    /// Names the database the catalogs describe, for an engine whose report covers one database only.
    var databaseQuery: String? { get }
    func query(for check: TableHealthCheckKind) -> String
    func findings(for check: TableHealthCheckKind, from result: QueryResult) -> [TableHealthFinding]
    func statisticsNote(from results: [QueryResult], now: Date) -> String?
}

extension TableHealthProvider {
    /// One failing check (a privilege, Performance Schema access) leaves the others standing.
    @MainActor
    func fetchReport(
        execute: @MainActor (String) async throws -> QueryResult,
        now: Date = Date()
    ) async throws -> TableHealthReport {
        var databaseName: String?
        if let databaseQuery {
            let result = try await execute(databaseQuery)
            databaseName = TableHealthRow.rows(of: result).first?["database_name"]
        }

        var results: [TableHealthCheckResult] = []
        for check in checks {
            do {
                let result = try await execute(query(for: check))
                results.append(TableHealthCheckResult(kind: check, findings: findings(for: check, from: result)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(TableHealthCheckResult(kind: check, findings: [], error: error.localizedDescription))
            }
        }

        var statisticsResults: [QueryResult] = []
        do {
            for query in statisticsQueries {
                statisticsResults.append(try await execute(query))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            statisticsResults = []
        }
        let note = statisticsResults.count == statisticsQueries.count
            ? statisticsNote(from: statisticsResults, now: now)
            : nil

        return TableHealthReport(checks: results, databaseName: databaseName, statisticsNote: note)
    }
}

enum TableHealthProviderFactory {
    static func provider(for databaseType: DatabaseType) -> TableHealthProvider? {
        switch databaseType {
        case .postgresql:
            return PostgreSQLTableHealthProvider()
        case .mysql, .mariadb:
            return MySQLTableHealthProvider()
        default:
            return nil
        }
    }
}

/// A result row read by column name, so a reordered SELECT list cannot shift a value.
struct TableHealthRow {
    private let values: [PluginCellValue]
    private let columns: [String: Int]

    static func rows(of result: QueryResult) -> [TableHealthRow] {
        var columns: [String: Int] = [:]
        for (index, name) in result.columns.enumerated() {
            columns[name.lowercased()] = index
        }
        return result.rows.map { TableHealthRow(values: $0, columns: columns) }
    }

    subscript(_ name: String) -> String {
        guard let index = columns[name], index < values.count else { return "" }
        return values[index].asText ?? ""
    }
}
