//
//  MCPAuthGuardTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MCP Auth Guard external access", .serialized)
@MainActor
struct MCPAuthGuardTests {
    private let storage = ConnectionStorage.shared

    private func withConnection(
        externalAccess: ExternalAccessLevel,
        aiPolicy: AIConnectionPolicy = .alwaysAllow,
        body: (UUID) async throws -> Void
    ) async throws {
        let original = storage.loadConnections()
        defer { storage.saveConnections(original) }

        let connection = DatabaseConnection(
            name: "MCP Test",
            type: .mysql,
            aiPolicy: aiPolicy,
            externalAccess: externalAccess
        )
        storage.saveConnections([connection])
        try await body(connection.id)
    }

    @Test("Read query passes when externalAccess is readOnly")
    func readQueryReadOnly() async throws {
        try await withConnection(externalAccess: .readOnly) { connectionId in
            let guardian = MCPAuthGuard()
            try await guardian.checkExternalWritePermission(
                connectionId: connectionId,
                sql: "SELECT * FROM users",
                databaseType: .mysql
            )
        }
    }

    @Test("Write query is blocked when externalAccess is readOnly")
    func writeQueryBlockedReadOnly() async throws {
        try await withConnection(externalAccess: .readOnly) { connectionId in
            let guardian = MCPAuthGuard()
            do {
                try await guardian.checkExternalWritePermission(
                    connectionId: connectionId,
                    sql: "UPDATE users SET name='x' WHERE id=1",
                    databaseType: .mysql
                )
                Issue.record("Expected MCPError.forbidden for write on read-only connection")
            } catch let error as MCPError {
                if case .forbidden = error {
                    return
                }
                Issue.record("Expected forbidden, got \(error)")
            }
        }
    }

    @Test("Write query passes when externalAccess is readWrite")
    func writeQueryAllowedReadWrite() async throws {
        try await withConnection(externalAccess: .readWrite) { connectionId in
            let guardian = MCPAuthGuard()
            try await guardian.checkExternalWritePermission(
                connectionId: connectionId,
                sql: "INSERT INTO users (id) VALUES (1)",
                databaseType: .mysql
            )
        }
    }

    @Test("Connection access blocked when externalAccess is blocked")
    func connectionAccessBlocked() async throws {
        try await withConnection(externalAccess: .blocked) { connectionId in
            let guardian = MCPAuthGuard()
            do {
                try await guardian.checkConnectionAccess(
                    connectionId: connectionId,
                    sessionId: "session-1"
                )
                Issue.record("Expected MCPError.forbidden for blocked connection")
            } catch let error as MCPError {
                if case .forbidden = error {
                    return
                }
                Issue.record("Expected forbidden, got \(error)")
            }
        }
    }

    @Test("Connection access allowed when externalAccess is readOnly")
    func connectionAccessAllowedReadOnly() async throws {
        try await withConnection(externalAccess: .readOnly) { connectionId in
            let guardian = MCPAuthGuard()
            try await guardian.checkConnectionAccess(
                connectionId: connectionId,
                sessionId: "session-1"
            )
        }
    }

    @Test("Missing connection rejects external write check")
    func missingConnectionRejectsExternalWrite() async {
        let guardian = MCPAuthGuard()
        let unknownId = UUID()
        do {
            try await guardian.checkExternalWritePermission(
                connectionId: unknownId,
                sql: "UPDATE foo SET bar=1",
                databaseType: .mysql
            )
            Issue.record("Expected MCPError.forbidden for missing connection")
        } catch let error as MCPError {
            if case .forbidden = error {
                return
            }
            Issue.record("Expected forbidden, got \(error)")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
