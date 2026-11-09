import Foundation

enum TableHealthError: LocalizedError, Equatable {
    case noDatabase

    var errorDescription: String? {
        String(localized: "Close this tab and choose Database > Table Health.")
    }
}

// The one read the Table Health tab and the MCP tool share. The caller fixes the scope, so a report never
// follows the sidebar to another database.
enum TableHealthReportLoader {
    // How the report reaches a driver.
    struct Lease: Sendable {
        let read: @Sendable (
            DatabaseScope,
            @escaping @Sendable (DatabaseDriver) async throws -> TableHealthReport
        ) async throws -> TableHealthReport

        // The bulk lane under a lease owner of its own: cancelling the task that awaits the report stops the
        // statement on the server, so a closed tab or an MCP timeout frees the lane for the next caller.
        static var cancellable: Lease {
            Lease { scope, body in
                let manager = await MainActor.run { DatabaseManager.shared }
                let route = await manager.metadataRoute(for: scope)
                return try await manager.withCancellableRead(scope: scope, route: route, workload: .bulk, body)
            }
        }

        static func metadata(_ metadata: any ScopedMetadataProviding) -> Lease {
            Lease { scope, body in
                try await metadata.withMetadataDriver(scope: scope, workload: .bulk, body)
            }
        }
    }

    static func load(
        provider: any TableHealthProvider,
        scope: DatabaseScope,
        lease: Lease,
        now: Date = Date()
    ) async throws -> TableHealthReport {
        guard !scope.isServerScoped else { throw TableHealthError.noDatabase }
        return try await lease.read(scope) { driver in
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
