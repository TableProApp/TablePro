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

    /// Whether `executeStartupCommands` would run anything. Shared with the metadata pool, which has
    /// to know whether the connection could have been moved out from under it, so the two cannot
    /// disagree about what counts as an empty command list.
    nonisolated internal static func hasStartupCommands(_ commands: String?) -> Bool {
        guard let commands else { return false }
        return !commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    nonisolated internal func executeStartupCommands(
        _ commands: String?, on driver: DatabaseDriver, connectionName: String
    ) async -> [(statement: String, error: String)] {
        guard Self.hasStartupCommands(commands), let commands else { return [] }

        let statements = commands
            .components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var failures: [(statement: String, error: String)] = []
        for statement in statements {
            do {
                _ = try await driver.execute(query: statement)
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
