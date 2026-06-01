//
//  DatabaseManager+Metadata.swift
//  TablePro
//

import Foundation

extension DatabaseManager {
    func withMetadataDriver<T: Sendable>(
        connectionId: UUID,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let session = session(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        return try await MetadataConnectionPool.shared.withDriver(
            connectionId: connectionId,
            database: session.activeDatabase,
            schema: session.currentSchema,
            workload: workload,
            body
        )
    }
}
