//
//  DatabaseManager+Metadata.swift
//  TablePro
//

import Foundation

/// Every metadata read states which database and schema it is for. There is deliberately
/// no connection-only overload: a connection reaches many databases, so resolving the
/// database from ambient session state is how a tab's read lands on another database.
@MainActor
protocol ScopedMetadataProviding: AnyObject {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T
}

extension ScopedMetadataProviding {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withMetadataDriver(scope: scope, workload: .interactive, body)
    }
}

extension DatabaseManager: ScopedMetadataProviding {}

extension DatabaseManager {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withScopedDriver(
            scope: scope,
            route: metadataRoute(for: scope),
            workload: workload,
            cancellation: .untracked,
            body
        )
    }

    /// For reads that belong to the connection rather than to any one window: the database
    /// and quick switchers, export, MCP, the AI schema context.
    ///
    /// A window-facing read must pass its own `browseScope` instead. Browsing is per window,
    /// so resolving the container here is how one window's read lands on another window's
    /// database.
    func withDriverScopedMetadataDriver<T: Sendable>(
        connectionId: UUID,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let scope = driverScope(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        return try await withMetadataDriver(scope: scope, workload: workload, body)
    }
}
