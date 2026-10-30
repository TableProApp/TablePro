//
//  SQLiteSessionScope.swift
//  TableProPluginKit
//

import Foundation

/// The session scopes of SQLite and libSQL's local file, which run every statement on the one connection the driver
/// holds. Only `PRAGMA foreign_keys` is held there; the verbatim purposes open none.
public enum SQLiteSessionScope {
    private static let foreignKeys = "foreign_keys"
    private static let on = "1"
    private static let off = "0"

    public static func open(
        for purpose: PluginSessionPurpose,
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> PluginSessionScope? {
        switch purpose {
        case .preserve:
            guard let saved = try await readForeignKeys(execute) else { return nil }
            return PluginSessionScope(purpose: purpose, saved: [saved], applied: [])
        case .relaxedForeignKeys:
            guard let saved = try await readForeignKeys(execute), saved.value == on else { return nil }
            _ = try await execute(assignment(off))
            // No scope reaches the caller past here, so nothing else would turn them back on.
            let readBack: PluginSessionSetting?
            do {
                readBack = try await readForeignKeys(execute)
            } catch {
                _ = try? await execute(assignment(on))
                throw error
            }
            // The pragma is a no-op while a transaction is open, and says so only when read back.
            guard readBack?.value == off else {
                _ = try? await execute(assignment(on))
                return nil
            }
            let applied = PluginSessionSetting(name: foreignKeys, value: off)
            return PluginSessionScope(purpose: purpose, saved: [saved], applied: [applied])
        case .verbatimRead, .verbatimWrite:
            return nil
        }
    }

    public static func close(
        _ scope: PluginSessionScope,
        execute: (String) async throws -> PluginQueryResult
    ) async throws {
        guard let saved = scope.saved.first(where: { $0.name == foreignKeys })?.value,
              try await readForeignKeys(execute)?.value != saved
        else { return }
        _ = try await execute(assignment(saved))
        guard try await readForeignKeys(execute)?.value == saved else {
            throw SQLiteSessionScopeError.transactionOpen
        }
    }

    private static func readForeignKeys(
        _ execute: (String) async throws -> PluginQueryResult
    ) async throws -> PluginSessionSetting? {
        switch try await execute("PRAGMA foreign_keys").rows.first?[safe: 0]?.asText?.lowercased() {
        case "1", "true": return PluginSessionSetting(name: foreignKeys, value: on)
        case "0", "false": return PluginSessionSetting(name: foreignKeys, value: off)
        default: return nil
        }
    }

    private static func assignment(_ value: String) -> String {
        "PRAGMA foreign_keys = \(value == on ? "ON" : "OFF")"
    }
}

private enum SQLiteSessionScopeError: LocalizedError {
    case transactionOpen

    var errorDescription: String? {
        String(localized: "Foreign key enforcement could not be put back while a transaction is open.")
    }
}
