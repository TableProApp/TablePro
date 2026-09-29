//
//  DashboardProviderSQLTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct DashboardProviderSQLTests {
    private final class StatementRecorder {
        private(set) var statements: [String] = []

        func record(_ sql: String) -> QueryResult {
            statements.append(sql)
            return .empty
        }
    }

    private struct LabeledProvider {
        let label: String
        let provider: ServerDashboardQueryProvider
    }

    private static let postgresVersionsWithOwnCatalog = ["9.1.24", "9.6.24", "17.11"]

    private static func everyProvider() -> [LabeledProvider] {
        let engines = DatabaseType.allKnownTypes.compactMap { type in
            ServerDashboardQueryProviderFactory.provider(for: type).map {
                LabeledProvider(label: type.rawValue, provider: $0)
            }
        }
        let postgresCatalogs = postgresVersionsWithOwnCatalog.compactMap { version in
            ServerDashboardQueryProviderFactory.provider(for: .postgresql, serverVersion: version).map {
                LabeledProvider(label: "PostgreSQL \(version)", provider: $0)
            }
        }
        return engines + postgresCatalogs
    }

    private static func statements(sentBy provider: ServerDashboardQueryProvider) async throws -> [String] {
        let recorder = StatementRecorder()
        _ = try await provider.fetchSessions { recorder.record($0) }
        _ = try await provider.fetchMetrics { recorder.record($0) }
        _ = try await provider.fetchSlowQueries { recorder.record($0) }
        return recorder.statements
    }

    @Test("Every dashboard statement is free of Swift digit separators")
    func noStatementCarriesADigitSeparator() async throws {
        let providers = Self.everyProvider()
        #expect(providers.count >= 10, "Only \(providers.count) providers; the walk would pass vacuously")
        for entry in providers {
            let statements = try await Self.statements(sentBy: entry.provider)
            #expect(!statements.isEmpty, "\(entry.label) sent nothing")
            for sql in statements {
                #expect(
                    sql.range(of: #"\d_\d"#, options: .regularExpression) == nil,
                    "\(entry.label) sends a digit separator the server reads as an identifier: \(sql)"
                )
            }
        }
    }
}
