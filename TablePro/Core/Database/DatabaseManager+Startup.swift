//
//  DatabaseManager+Startup.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import os
import TableProPluginKit

// MARK: - Startup Commands

extension DatabaseManager {
    nonisolated private static let startupLogger = Logger(subsystem: "com.TablePro", category: "DatabaseManager")

    @discardableResult
    nonisolated internal func executeStartupCommands(
        _ commands: String?,
        on driver: DatabaseDriver,
        connectionId: UUID,
        databaseType: DatabaseType,
        connectionName: String
    ) async -> [(statement: String, error: String)] {
        guard let commands, !commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let statements = commands
            .components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var failures: [(statement: String, error: String)] = []
        for statement in statements {
            do {
                let request = OperationRequest.backgroundMaintenance(
                    connectionId: connectionId,
                    databaseType: databaseType,
                    sql: statement,
                    operationDescription: String(localized: "Run Startup Command")
                )
                _ = try await driver.executeAuthorizing(query: statement, request: request)
                Self.startupLogger.info(
                    "Startup command succeeded for '\(connectionName)': \(statement)"
                )
            } catch {
                Self.startupLogger.warning(
                    "Startup command failed for '\(connectionName)': \(statement) — \(error.localizedDescription)"
                )
                failures.append((statement: statement, error: error.localizedDescription))
            }
        }
        return failures
    }
}
