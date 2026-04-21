//
//  MCPAuthGuard.swift
//  TablePro
//
//  Enforces AIConnectionPolicy and SafeModeLevel for MCP requests.
//

import AppKit
import Foundation
import os

actor MCPAuthGuard {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPAuthGuard")

    /// Per-session approved connections (for askEachTime policy)
    private var sessionApprovals: [String: Set<UUID>] = [:]

    // MARK: - Connection Access Check

    func checkConnectionAccess(connectionId: UUID, sessionId: String) async throws {
        let (policy, connectionName, databaseType) = await MainActor.run {
            let conns = ConnectionStorage.shared.loadConnections()
            guard let conn = conns.first(where: { $0.id == connectionId }) else {
                return (AIConnectionPolicy.never, "", "")
            }
            let effective = conn.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy
            return (effective, conn.name, conn.type.rawValue)
        }

        switch policy {
        case .alwaysAllow:
            return

        case .never:
            throw MCPError.forbidden(
                String(localized: "AI access is disabled for this connection")
            )

        case .askEachTime:
            if let approved = sessionApprovals[sessionId], approved.contains(connectionId) {
                return
            }

            let userApproved = try await promptUserApproval(
                connectionName: connectionName,
                databaseType: databaseType
            )

            if userApproved {
                sessionApprovals[sessionId, default: []].insert(connectionId)
            } else {
                throw MCPError.forbidden(
                    String(localized: "User denied MCP access to this connection")
                )
            }
        }
    }

    // MARK: - Query Permission Check

    func checkQueryPermission(
        sql: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel
    ) async throws {
        let isWrite = QueryClassifier.isWriteQuery(sql, databaseType: databaseType)

        // SafeModeGuard.checkPermission is @MainActor async; Swift hops automatically
        let permission = await SafeModeGuard.checkPermission(
            level: safeModeLevel,
            isWriteOperation: isWrite,
            sql: sql,
            operationDescription: String(localized: "MCP query execution"),
            window: nil,
            databaseType: databaseType
        )

        if case .blocked(let reason) = permission {
            throw MCPError.forbidden(reason)
        }
    }

    // MARK: - Query Logging

    func logQuery(
        sql: String,
        connectionId: UUID,
        databaseName: String,
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String?
    ) async {
        let shouldLog = await MainActor.run {
            AppSettingsManager.shared.mcp.logQueriesInHistory
        }
        guard shouldLog else { return }

        let entry = QueryHistoryEntry(
            query: sql,
            connectionId: connectionId,
            databaseName: databaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )

        _ = await QueryHistoryStorage.shared.addHistory(entry)
    }

    // MARK: - User Approval (askEachTime)

    private func promptUserApproval(connectionName: String, databaseType: String) async throws -> Bool {
        // Use a task group so the actor suspends (freeing it for other requests)
        // while the approval dialog is shown on the main thread.
        // Race the dialog against a 30-second timeout.
        let approvalTask = Task { @MainActor in
            NSApp.requestUserAttention(.criticalRequest)
            NSApp.activate(ignoringOtherApps: true)
            return await AlertHelper.confirmDestructive(
                title: String(localized: "MCP Access Request"),
                message: String(
                    format: String(localized: "An MCP client wants to access '%@' (%@). Allow?"),
                    connectionName,
                    databaseType
                ),
                confirmButton: String(localized: "Allow"),
                cancelButton: String(localized: "Deny"),
                window: nil
            )
        }

        let approved = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await approvalTask.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                approvalTask.cancel()
                throw MCPError.timeout(
                    String(localized: "User approval timed out after 30 seconds")
                )
            }
            guard let result = try await group.next() else {
                throw MCPError.internalError("No result from approval prompt")
            }
            approvalTask.cancel()
            group.cancelAll()
            return result
        }

        if approved {
            return true
        }
        throw MCPError.forbidden(
            String(localized: "User denied MCP access to this connection")
        )
    }

    // MARK: - Session Cleanup

    func clearSession(_ sessionId: String) {
        sessionApprovals.removeValue(forKey: sessionId)
    }
}
