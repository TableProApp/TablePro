//
//  DatabaseManager+Metadata.swift
//  TablePro
//

import Foundation

/// Every metadata read states which database and schema it is for. There is deliberately
/// no connection-only overload: a connection reaches many databases, so resolving the
/// database from ambient session state is how a tab's read lands on another database.
@MainActor
protocol ScopedMetadataProviding: AnyObject, Sendable {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T

    func browseScope(for connectionId: UUID) -> DatabaseScope?
}

extension ScopedMetadataProviding {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withMetadataDriver(scope: scope, workload: .interactive, body)
    }

    /// For reads that belong to the sidebar rather than to a tab: the object list, the
    /// database and quick switchers, and the AI schema context. Completion is not one of
    /// them any more: a query tab completes against its own scope.
    func withBrowseMetadataDriver<T: Sendable>(
        connectionId: UUID,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let scope = browseScope(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        return try await withMetadataDriver(scope: scope, workload: workload, body)
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
}
