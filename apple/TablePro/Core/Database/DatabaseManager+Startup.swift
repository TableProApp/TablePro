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

    nonisolated internal func executeStartupCommands(
        _ commands: String?, on driver: DatabaseDriver, connectionName: String
    ) async -> [StartupCommandFailure] {
        var failures: [StartupCommandFailure] = []
        let databaseType = driver.connection.type
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        for statement in Self.startupStatements(from: commands, databaseType: databaseType, grammar: grammar) {
            do {
                _ = try await driver.execute(query: statement)
                Self.startupLogger.info(
                    "Startup command succeeded for '\(connectionName, privacy: .private)': \(statement, privacy: .private)"
                )
            } catch {
                Self.startupLogger.warning(
                    "Startup command failed for '\(connectionName, privacy: .private)': \(statement, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
                failures.append(StartupCommandFailure(statement: statement, error: error))
            }
        }
        return failures
    }

    // A startup command can be a safety rail, `SET ROLE app_ro` or a read-only default, so a session that opened
    // without one says so on the connection's warning rather than only in the log.
    nonisolated internal static func startupWarning(for failures: [StartupCommandFailure]) -> String? {
        guard let first = failures.first else { return nil }
        guard failures.count > 1 else {
            guard let code = first.code else {
                return String(
                    format: String(localized: "The startup command %@ failed, so this session runs without it."),
                    shownStatement(first.statement)
                )
            }
            return String(
                format: String(localized: "The startup command %1$@ failed (%2$@), so this session runs without it."),
                shownStatement(first.statement), code
            )
        }
        let lines = failures.map { failure in
            failure.code.map { "\(shownStatement(failure.statement)) (\($0))" } ?? shownStatement(failure.statement)
        }
        return String(
            format: String(localized: "Startup commands failed, so this session runs without them:\n%@"),
            lines.joined(separator: "\n")
        )
    }

    // A startup command can carry a secret, a password after IDENTIFIED BY or a key in a literal, so the banner shows
    // it only up to its first quote or credential clause.
    nonisolated internal static func shownStatement(_ statement: String) -> String {
        let quote = statement.firstIndex(where: { $0 == "'" || $0 == "\"" || $0 == "$" })
        let stops = [quote] + ["IDENTIFIED", "PASSWORD"].map { statement.range(of: $0, options: .caseInsensitive)?.lowerBound }
        let cut = stops.compactMap { $0 }.min() ?? statement.endIndex
        let kept = statement[..<cut].trimmingCharacters(in: .whitespaces)
        let limit = 200
        guard cut < statement.endIndex || kept.count > limit else { return kept }
        return String(kept.prefix(limit)) + "…"
    }

    nonisolated internal static func joinedWarning(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: "\n\n")
    }

    // The warning a session opens with: the login's own, then what its setup could not do. It replaces the previous
    // one, so a reconnect that ran every startup command drops a banner about the session before it, and the record
    // of named failures starts over.
    internal func openingWarning(
        driver: DatabaseDriver,
        startupFailures: [StartupCommandFailure],
        restoreWarning: String? = nil,
        for connectionId: UUID
    ) -> String? {
        reportedStartupFailures[connectionId] = Set(startupFailures.map { $0.statement })
        return Self.joinedWarning([driver.connectionWarning, Self.startupWarning(for: startupFailures), restoreWarning])
    }

    // A pool entry or a database lane opens a session of its own, which can fail a command the window's session ran.
    // Each failing statement is named once per connect: the pool keeps opening entries while the window is open.
    internal func reportStartupFailures(_ failures: [StartupCommandFailure], for connectionId: UUID) {
        guard activeSessions[connectionId] != nil else { return }
        var reported = reportedStartupFailures[connectionId] ?? []
        let unreported = failures.filter { reported.insert($0.statement).inserted }
        reportedStartupFailures[connectionId] = reported
        guard let warning = Self.startupWarning(for: unreported) else { return }
        updateSession(connectionId) { session in
            session.connectionWarning = Self.joinedWarning([session.connectionWarning, warning])
        }
    }
}

// What the banner may show of a failed startup command: the statement and the server's code, never its message, which
// can echo the values the statement carried. The message goes to the log, private.
struct StartupCommandFailure: Sendable, Equatable {
    let statement: String
    let code: String?

    init(statement: String, code: String?) {
        self.statement = statement
        self.code = code
    }

    init(statement: String, error: Error) {
        self.init(statement: statement, code: Self.code(of: error))
    }

    static func code(of error: Error) -> String? {
        guard let driverError = error as? any PluginDriverError else { return nil }
        if let state = driverError.pluginSqlState, !state.isEmpty { return state }
        if let code = driverError.pluginErrorCode, code != 0 { return String(code) }
        return nil
    }
}
