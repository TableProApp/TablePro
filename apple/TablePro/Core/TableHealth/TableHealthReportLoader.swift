import Foundation

enum TableHealthError: LocalizedError, Equatable {
    case noDatabase

    var errorDescription: String? {
        String(localized: "Select a database in the sidebar to check its tables.")
    }
}

// The one read the Table Health tab and the MCP tool share. The caller fixes the scope, so a report never
// follows the sidebar to another database.
enum TableHealthReportLoader {
    static func load(
        provider: any TableHealthProvider,
        scope: DatabaseScope,
        metadata: any ScopedMetadataProviding,
        now: Date = Date()
    ) async throws -> TableHealthReport {
        guard !scope.isServerScoped else { throw TableHealthError.noDatabase }
        return try await metadata.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            let context = TableHealthQueryContext(
                database: scope.database,
                quote: { driver.quoteIdentifier($0) },
                literal: { "'" + driver.escapeStringLiteral($0) + "'" }
            )
            return try await provider.fetchReport(context: context, now: now) { query in
                try await driver.executeCatalogRead(query: query)
            }
        }
    }
}
