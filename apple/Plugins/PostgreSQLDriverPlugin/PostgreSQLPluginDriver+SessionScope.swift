//
//  PostgreSQLPluginDriver+SessionScope.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProLogRedaction
import TableProPluginKit

/// On this class rather than `LibPQBackedDriver`, so CockroachDB and Redshift keep PluginKit's nil scopes: this rests
/// on PostgreSQL's `pg_settings`, `set_config` and savepoints, measured on 17.11 only.
internal extension PostgreSQLPluginDriver {
    private static let scopeLogger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "PostgreSQLSessionScope")

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        switch purpose {
        case .preserve:
            guard let saved = await captureSessionSettings(PostgreSQLSessionScopeSQL.preservedNames),
                  !saved.isEmpty else { return nil }
            return PluginSessionScope(purpose: .preserve, saved: saved, applied: [])
        case .verbatimRead:
            return await openVerbatimReadScope()
        case .verbatimWrite:
            // What the read pins reads back the same under any settings; nil would make the host drop the read too.
            return PluginSessionScope(purpose: .verbatimWrite, saved: [], applied: [])
        case .relaxedForeignKeys:
            // `session_replication_role = replica` would also stop the target's user triggers, and needs a superuser.
            return nil
        @unknown default:
            return nil
        }
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        guard !scope.saved.isEmpty else { return }
        try await restoreChangedSessionSettings(scope.saved)
    }

    private func openVerbatimReadScope() async -> PluginSessionScope? {
        guard PostgreSQLSessionScopeSQL.canOpenReadScope(in: await core.sessionTransactionState()) else {
            Self.scopeLogger.info("Read scope not opened: the session has a transaction open")
            return nil
        }
        let requested = PostgreSQLSessionScopeSQL.verbatimReadSettings
        let names = PostgreSQLSessionScopeSQL.verbatimReadNames
        guard let captured = await captureSessionSettings(names),
              let saved = PostgreSQLSessionScopeSQL.completeSettings(captured, names: names),
              let statement = PostgreSQLSessionScopeSQL.setStatement(requested)
        else {
            Self.scopeLogger.info("Read scope not opened: the server lacks one of its settings or the capture failed")
            return nil
        }
        do {
            let rows = try await core.executeSessionSetting(statement, requiresIdleSession: true)
            let applied = PostgreSQLSessionScopeSQL.appliedSettings(
                requested,
                reportedRow: rows.first?.map(\.asText) ?? []
            )
            return PluginSessionScope(purpose: .verbatimRead, saved: saved, applied: applied)
        } catch PostgreSQLSessionScopeError.sessionNotIdle {
            Self.scopeLogger.info("Read scope not opened: a transaction opened before its settings were applied")
            return nil
        } catch {
            // One statement outside a transaction: a refusal rolls back all of it, so nothing needs putting back.
            Self.scopeLogger.error(
                "Read scope not opened, its settings were refused: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private func captureSessionSettings(_ names: [String]) async -> [PluginSessionSetting]? {
        guard PostgreSQLSessionScopeSQL.canRestore(in: await core.sessionTransactionState()) else {
            Self.scopeLogger.info("Session scope not opened: the session is in an aborted transaction")
            return nil
        }
        do {
            let rows = try await core.executeSessionSetting(PostgreSQLSessionScopeSQL.captureStatement(names: names))
            return PostgreSQLSessionScopeSQL.settings(fromRows: rows.map { $0.map(\.asText) }, names: names)
        } catch {
            Self.scopeLogger.error(
                "Session settings capture failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    /// Nothing is sent in an aborted transaction: the server would refuse it, and the rollback the session still
    /// needs reverts only what the transaction itself set, so the caller is told rather than left to assume.
    private func restoreChangedSessionSettings(_ saved: [PluginSessionSetting]) async throws {
        guard PostgreSQLSessionScopeSQL.canRestore(in: await core.sessionTransactionState()) else {
            Self.scopeLogger.error("Session settings not restored: the session is in an aborted transaction")
            throw PostgreSQLSessionScopeError.abortedTransaction
        }
        let names = saved.map(\.name)
        let rows = try await core.executeSessionSetting(PostgreSQLSessionScopeSQL.captureStatement(names: names))
        let current = PostgreSQLSessionScopeSQL.settings(fromRows: rows.map { $0.map(\.asText) }, names: names)

        var refused: [String] = []
        for setting in PostgreSQLSessionScopeSQL.changedSettings(saved: saved, current: current) {
            guard let statement = PostgreSQLSessionScopeSQL.setStatement([setting]) else { continue }
            do {
                _ = try await core.executeSessionSetting(statement)
            } catch {
                refused.append(setting.name)
                Self.scopeLogger.error(
                    "Restoring \(setting.name, privacy: .public) failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        guard refused.isEmpty else { throw PostgreSQLSessionScopeError.restoreRefused(refused) }
    }
}
