import Foundation
import TableProPluginKit

struct TableHealthQueryContext {
    let database: String
    let quote: (String) -> String

    func qualified(_ parts: String...) -> String {
        parts.map(quote).joined(separator: ".")
    }
}

protocol TableHealthProvider: Sendable {
    var checks: [TableHealthCheckKind] { get }
    var statisticsQueries: [String] { get }
    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics
    func queries(for check: TableHealthCheckKind) -> [String]
    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext
    ) -> [TableHealthFinding]
}

extension TableHealthProvider {
    // One failing check, a missing privilege say, leaves the others standing.
    func fetchReport(
        context: TableHealthQueryContext,
        now: Date = Date(),
        execute: (String) async throws -> QueryResult
    ) async throws -> TableHealthReport {
        var answered: [String: Result<QueryResult, any Error>] = [:]
        func run(_ query: String) async throws -> QueryResult {
            if let answer = answered[query] { return try answer.get() }
            try Task.checkCancellation()
            do {
                let result = try await execute(query)
                answered[query] = .success(result)
                return result
            } catch let error as CancellationError {
                throw error
            } catch {
                answered[query] = .failure(error)
                throw error
            }
        }

        var statisticsResults: [QueryResult?] = []
        for query in statisticsQueries {
            do {
                statisticsResults.append(try await run(query))
            } catch let error as CancellationError {
                throw error
            } catch {
                statisticsResults.append(nil)
            }
        }
        let statistics = statistics(from: statisticsResults, now: now)

        var results: [TableHealthCheckResult] = []
        for check in checks {
            if let reason = statistics.skippedChecks[check] {
                results.append(TableHealthCheckResult(kind: check, findings: [], outcome: .skipped(reason)))
                continue
            }
            do {
                var inputs: [QueryResult] = []
                for query in queries(for: check) {
                    inputs.append(try await run(query))
                }
                let found = findings(for: check, from: inputs, context: context)
                results.append(TableHealthCheckResult(kind: check, findings: found, outcome: .completed))
            } catch let error as CancellationError {
                throw error
            } catch {
                results.append(TableHealthCheckResult(
                    kind: check, findings: [], outcome: .failed(error.localizedDescription)
                ))
            }
        }
        return TableHealthReport(database: context.database, checks: results, statisticsNote: statistics.note)
    }
}

enum TableHealthProviderFactory {
    static func provider(for databaseType: DatabaseType) -> (any TableHealthProvider)? {
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

// Read by column name, so a reordered SELECT list cannot shift a value.
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

enum TableHealthFormatting {
    static func count(_ text: String) -> String {
        guard let value = Int64(text) else { return text }
        return value.formatted()
    }
}
