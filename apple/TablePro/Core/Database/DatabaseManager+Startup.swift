//
//  DatabaseManager+Startup.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import os
import TableProPluginKit
import TableProRedisCore
import TableProSQLGrammar

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

    /// The statements `executeStartupCommands` sends, one per line or `;`, read the way the session reads a quote or a
    /// comment. Also read by the catalog, because a temporary table a startup command creates shadows a real one for
    /// the whole session.
    nonisolated internal static func startupStatements(
        from commands: String?,
        databaseType: DatabaseType,
        grammar sessionGrammar: SQLLexicalGrammar? = nil
    ) -> [String] {
        guard hasStartupCommands(commands), let commands else { return [] }
        if QueryStatementModel.forDatabaseType(databaseType) == .redis {
            return RedisCommandSplitter.commands(in: commands).map(\.text)
        }
        let grammar = sessionGrammar ?? databaseType.lexicalGrammar
        let source = commands as NSString
        var statements: [String] = []
        var lineStart = 0
        func scanLine(to end: Int) {
            let line = source.substring(with: NSRange(location: lineStart, length: end - lineStart))
            statements += SQLStatementScanner.executableStatements(in: line, grammar: grammar).map(\.sql)
        }
        var index = 0
        while index < source.length {
            if let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) {
                index = max(span.end, index + 1)
                continue
            }
            let unit = source.character(at: index)
            if unit == SqlLexer.newline || unit == SqlLexer.carriageReturn {
                scanLine(to: index)
                lineStart = index + 1
            }
            index += 1
        }
        scanLine(to: source.length)
        return statements
    }

    @discardableResult
    nonisolated internal func executeStartupCommands(
        _ commands: String?, on driver: DatabaseDriver, connectionName: String
    ) async -> [(statement: String, error: String)] {
        var failures: [(statement: String, error: String)] = []
        let databaseType = driver.connection.type
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        for statement in Self.startupStatements(from: commands, databaseType: databaseType, grammar: grammar) {
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
