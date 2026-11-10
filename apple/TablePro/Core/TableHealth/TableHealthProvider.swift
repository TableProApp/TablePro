import Foundation
import TableProPluginKit

struct TableHealthQueryContext {
    let database: String
    let quote: (String) -> String
    // A whole string literal, quotes included.
    let literal: (String) -> String

    func qualified(_ parts: String...) -> String {
        parts.map(quote).joined(separator: ".")
    }
}

protocol TableHealthProvider: Sendable {
    var checks: [TableHealthCheckKind] { get }
    var statisticsQueries: [String] { get }
    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics
    func check(_ kind: TableHealthCheckKind) -> TableHealthCheck
    func queries(for check: TableHealthCheckKind, statistics: TableHealthStatistics) -> [String]
    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext,
        statistics: TableHealthStatistics
    ) -> (findings: [TableHealthFinding], note: String?)
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
        for kind in checks {
            let descriptor = check(kind)
            if let reason = statistics.skippedChecks[kind] {
                results.append(TableHealthCheckResult(check: descriptor, findings: [], outcome: .skipped(reason)))
                continue
            }
            do {
                var inputs: [QueryResult] = []
                for query in queries(for: kind, statistics: statistics) {
                    inputs.append(try await run(query))
                }
                let output = findings(for: kind, from: inputs, context: context, statistics: statistics)
                results.append(TableHealthCheckResult(
                    check: descriptor, findings: output.findings, outcome: .completed, note: output.note
                ))
            } catch let error as CancellationError {
                throw error
            } catch {
                results.append(TableHealthCheckResult(
                    check: descriptor, findings: [], outcome: .failed(error.localizedDescription)
                ))
            }
        }
        return TableHealthReport(
            database: context.database, checks: results, notes: statistics.notes, generatedAt: now
        )
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
        text(name) ?? ""
    }

    // Nil for NULL and for a column the result does not have.
    func text(_ name: String) -> String? {
        guard let index = columns[name], index < values.count else { return nil }
        return values[index].asText
    }

    // A server can print an integer column as a decimal ("1.5e+06", "42.0"), so a whole Double is taken too.
    func int64(_ name: String) -> Int64? {
        guard let text = self.text(name)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let value = Int64(text) { return value }
        guard let value = Double(text), value.isFinite, value >= Double(Int64.min), value < Double(Int64.max)
        else { return nil }
        return Int64(value.rounded())
    }

    func uint64(_ name: String) -> UInt64? {
        guard let text = self.text(name)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let value = UInt64(text) { return value }
        guard let value = Double(text), value.isFinite, value >= 0, value < Double(UInt64.max) else { return nil }
        return UInt64(value.rounded())
    }

    func double(_ name: String) -> Double? {
        guard let text = self.text(name)?.trimmingCharacters(in: .whitespaces), let value = Double(text), value.isFinite
        else { return nil }
        return value
    }

    // Queries return dates as Unix epoch seconds, so no server time zone or text format reaches the app.
    func date(_ name: String) -> Date? {
        double(name).map { Date(timeIntervalSince1970: $0) }
    }

    func flag(_ name: String) -> Bool? {
        guard let text = self.text(name) else { return nil }
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "t", "true", "1", "yes", "on": return true
        case "f", "false", "0", "no", "off": return false
        default: return nil
        }
    }
}
