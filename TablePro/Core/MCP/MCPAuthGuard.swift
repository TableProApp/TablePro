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

    /// In-flight approval prompts keyed by (sessionId, connectionId) to dedupe concurrent requests.
    private var inFlightApprovals: [ApprovalKey: Task<Bool, Error>] = [:]

    private struct ApprovalKey: Hashable {
        let sessionId: String
        let connectionId: UUID
    }

    // MARK: - Connection Access Check

    func checkConnectionAccess(connectionId: UUID, sessionId: String) async throws {
        let snapshot: ConnectionAccessSnapshot? = await MainActor.run {
            let conns = ConnectionStorage.shared.loadConnections()
            guard let conn = conns.first(where: { $0.id == connectionId }) else {
                return nil
            }
            return ConnectionAccessSnapshot(
                policy: conn.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
                externalAccess: conn.externalAccess,
                name: conn.name,
                databaseType: conn.type.rawValue
            )
        }

        guard let snapshot else {
            throw MCPError.forbidden(
                String(localized: "Connection not found")
            )
        }

        switch snapshot.policy {
        case .alwaysAllow:
            break

        case .never:
            throw MCPError.forbidden(
                String(localized: "AI access is disabled for this connection")
            )

        case .askEachTime:
            if let approved = sessionApprovals[sessionId], approved.contains(connectionId) {
                break
            }

            let key = ApprovalKey(sessionId: sessionId, connectionId: connectionId)
            let approvalTask: Task<Bool, Error>
            if let existing = inFlightApprovals[key] {
                approvalTask = existing
            } else {
                let connectionName = snapshot.name
                let databaseType = snapshot.databaseType
                approvalTask = Task {
                    try await self.promptUserApproval(
                        connectionName: connectionName,
                        databaseType: databaseType
                    )
                }
                inFlightApprovals[key] = approvalTask
            }

            let userApproved: Bool
            do {
                userApproved = try await approvalTask.value
                inFlightApprovals.removeValue(forKey: key)
            } catch {
                inFlightApprovals.removeValue(forKey: key)
                throw error
            }

            if userApproved {
                sessionApprovals[sessionId, default: []].insert(connectionId)
            } else {
                throw MCPError.forbidden(
                    String(localized: "User denied MCP access to this connection")
                )
            }
        }

        if snapshot.externalAccess == .blocked {
            throw MCPError.forbidden(
                String(localized: "External access is disabled for this connection")
            )
        }
    }

    func checkExternalAccessLevel(
        connectionId: UUID,
        requires required: ExternalAccessLevel
    ) async throws {
        let externalAccess: ExternalAccessLevel? = await MainActor.run {
            ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }?.externalAccess
        }

        guard let externalAccess else {
            throw MCPError.forbidden(
                String(localized: "Connection not found")
            )
        }

        guard externalAccess.satisfies(required) else {
            throw MCPError.forbidden(
                String(localized: "Connection is read-only for external clients")
            )
        }
    }

    func checkExternalWritePermission(
        connectionId: UUID,
        sql: String,
        databaseType: DatabaseType
    ) async throws {
        guard QueryClassifier.isWriteQuery(sql, databaseType: databaseType) else { return }

        let externalAccess: ExternalAccessLevel? = await MainActor.run {
            ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }?.externalAccess
        }

        guard let externalAccess else {
            throw MCPError.forbidden(
                String(localized: "Connection not found")
            )
        }

        if externalAccess != .readWrite {
            throw MCPError.forbidden(
                String(localized: "Connection is read-only for external clients")
            )
        }
    }

    private struct ConnectionAccessSnapshot: Sendable {
        let policy: AIConnectionPolicy
        let externalAccess: ExternalAccessLevel
        let name: String
        let databaseType: String
    }

    // MARK: - Query Permission Check

    func checkQueryPermission(
        sql: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel
    ) async throws {
        try await checkExternalWritePermission(
            connectionId: connectionId,
            sql: sql,
            databaseType: databaseType
        )

        let isWrite = QueryClassifier.isWriteQuery(sql, databaseType: databaseType)
        let needsDialog = safeModeLevel != .silent && (isWrite || safeModeLevel == .alertFull || safeModeLevel == .safeModeFull)

        var window: NSWindow?
        if needsDialog {
            window = await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                return NSApp.keyWindow ?? NSApp.mainWindow
            }
        }

        let permission = await SafeModeGuard.checkPermission(
            level: safeModeLevel,
            isWriteOperation: isWrite,
            sql: sql,
            operationDescription: String(localized: "MCP query execution"),
            window: window,
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
        let approved = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await AlertHelper.runApprovalModal(
                    title: String(localized: "MCP Access Request"),
                    message: String(
                        format: String(localized: "An MCP client wants to access '%@' (%@). Allow?"),
                        connectionName,
                        databaseType
                    ),
                    confirm: String(localized: "Allow"),
                    cancel: String(localized: "Deny")
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw MCPError.timeout(
                    String(localized: "User approval timed out after 30 seconds")
                )
            }
            guard let result = try await group.next() else {
                throw MCPError.internalError("No result from approval prompt")
            }
            group.cancelAll()
            return result
        }

        guard approved else {
            throw MCPError.forbidden(
                String(localized: "User denied MCP access to this connection")
            )
        }
        return true
    }

    // MARK: - Session Cleanup

    func clearSession(_ sessionId: String) {
        sessionApprovals.removeValue(forKey: sessionId)
    }
}
