//
//  MCPToolHandlerExportTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MCP Tool Handler — export_data validation", .serialized)
@MainActor
struct MCPToolHandlerExportTests {
    private let storage = ConnectionStorage.shared

    private func makeHandler() -> MCPToolHandler {
        MCPToolHandler(bridge: MCPConnectionBridge(), authGuard: MCPAuthGuard())
    }

    private func withConnections(
        _ connections: [DatabaseConnection],
        body: () async throws -> Void
    ) async throws {
        let original = storage.loadConnections()
        defer { storage.saveConnections(original) }
        storage.saveConnections(connections)
        try await body()
    }

    @Test("export_data rejects table name with SQL injection payload")
    func exportDataRejectsInjectionInTableName() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(
            name: "Target",
            type: .mysql,
            aiPolicy: .alwaysAllow,
            externalAccess: .readWrite
        )
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "export_data",
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "format": .string("csv"),
                        "tables": .array([.string("users; DROP TABLE users;--")])
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.invalidParams for malicious table name")
            } catch let error as MCPError {
                if case .invalidParams = error { return }
                Issue.record("Expected invalidParams, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("export_data rejects table name with quote payload")
    func exportDataRejectsQuotePayload() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(
            name: "Target",
            type: .mysql,
            aiPolicy: .alwaysAllow,
            externalAccess: .readWrite
        )
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "export_data",
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "format": .string("csv"),
                        "tables": .array([.string("users`; DROP TABLE x;--")])
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.invalidParams for backtick injection")
            } catch let error as MCPError {
                if case .invalidParams = error { return }
                Issue.record("Expected invalidParams, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }

    @Test("validateExportTableName accepts simple identifiers")
    func validateExportTableNameAcceptsSimple() throws {
        try MCPToolHandler.validateExportTableName("users")
        try MCPToolHandler.validateExportTableName("users_v2")
        try MCPToolHandler.validateExportTableName("public.users")
        try MCPToolHandler.validateExportTableName("schema.table_name_42")
    }

    @Test("validateExportTableName rejects spaces")
    func validateExportTableNameRejectsSpaces() {
        do {
            try MCPToolHandler.validateExportTableName("users x")
            Issue.record("Expected throw for table name with space")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("validateExportTableName rejects semicolon")
    func validateExportTableNameRejectsSemicolon() {
        do {
            try MCPToolHandler.validateExportTableName("users;DROP TABLE x")
            Issue.record("Expected throw for table name with semicolon")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("validateExportTableName rejects empty string")
    func validateExportTableNameRejectsEmpty() {
        do {
            try MCPToolHandler.validateExportTableName("")
            Issue.record("Expected throw for empty table name")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("validateExportTableName rejects leading dot")
    func validateExportTableNameRejectsLeadingDot() {
        do {
            try MCPToolHandler.validateExportTableName(".users")
            Issue.record("Expected throw for table name with leading dot")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("export_data rejects output_path outside Downloads")
    func exportDataRejectsPathOutsideDownloads() async throws {
        let handler = makeHandler()
        let connection = DatabaseConnection(
            name: "Target",
            type: .mysql,
            aiPolicy: .alwaysAllow,
            externalAccess: .readWrite
        )
        try await withConnections([connection]) {
            do {
                _ = try await handler.handleToolCall(
                    name: "export_data",
                    arguments: .object([
                        "connection_id": .string(connection.id.uuidString),
                        "format": .string("csv"),
                        "query": .string("SELECT 1"),
                        "output_path": .string("/tmp/escape.csv")
                    ]),
                    sessionId: "test-session",
                    token: nil
                )
                Issue.record("Expected MCPError.invalidParams for path outside Downloads")
            } catch let error as MCPError {
                if case .invalidParams = error { return }
                Issue.record("Expected invalidParams, got \(error)")
            } catch {
                Issue.record("Expected MCPError, got \(error)")
            }
        }
    }
}
