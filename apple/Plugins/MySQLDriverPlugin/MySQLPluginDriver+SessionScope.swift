//
//  MySQLPluginDriver+SessionScope.swift
//  MySQLDriverPlugin
//

import Foundation
import os
import TableProMySQLCore
import TableProPluginKit

internal extension MySQLPluginDriver {
    /// Databend has no `sql_mode` or foreign key checks to hold, and a server before 5.0.3 cannot filter `SHOW` with
    /// `WHERE`.
    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        let names = MySQLSessionScopePlan.savedNames(for: purpose)
        guard !flavor.isDatabend,
              holdsForServer(MySQLServerVersion.showAcceptsWhere(banner:flavor:)),
              !names.isEmpty
        else { return nil }
        let saved = try await readSessionSettings(names)
        guard let applied = MySQLSessionScopePlan.applied(for: purpose, saved: saved) else { return nil }
        guard !applied.isEmpty else {
            return PluginSessionScope(purpose: purpose, saved: saved, applied: [])
        }
        let statements = applied.compactMap { MySQLSessionStatements.assignment(name: $0.name, value: $0.value) }
        let savedNames = Set(saved.map(\.name))
        /// A setting with no saved value could not be put back, so the scope sets none of them.
        guard statements.count == applied.count, applied.allSatisfy({ savedNames.contains($0.name) }) else {
            Self.logger.warning("The server did not report every setting a session scope sets; running without one")
            return nil
        }
        /// Held before the first `SET`, so the idle release cannot hand the session back between two of them.
        adjustFootprint { $0.holdSessionScope() }
        do {
            for statement in statements {
                _ = try await executeSetup(statement)
            }
        } catch {
            let isRestored = await restoreAfterFailedOpen(saved)
            adjustFootprint { $0.releaseSessionScope(isRestored: isRestored) }
            throw error
        }
        return PluginSessionScope(purpose: purpose, saved: saved, applied: applied)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        guard !flavor.isDatabend else { return }
        let heldSession = !scope.applied.isEmpty
        let isRestored: Bool
        do {
            isRestored = try await restoreSessionSettings(scope.saved)
        } catch {
            noteClosedScope(heldSession: heldSession, isRestored: false)
            throw error
        }
        noteClosedScope(heldSession: heldSession, isRestored: isRestored)
    }

    private func noteClosedScope(heldSession: Bool, isRestored: Bool) {
        adjustFootprint { footprint in
            if heldSession {
                footprint.releaseSessionScope(isRestored: isRestored)
            } else if !isRestored {
                footprint.noteUnrestoredSessionSettings()
            }
        }
    }

    private func readSessionSettings(_ names: [String]) async throws -> [PluginSessionSetting] {
        guard let query = MySQLSessionStatements.captureQuery(names: names) else { return [] }
        let result = try await executeSetup(query)
        return MySQLSessionScopePlan.captured(rows: result.rows, names: names)
    }

    /// Every statement is tried, so one refused value does not leave the others changed, and the first refusal is what
    /// the caller hears. False when a setting had to stay changed.
    ///
    /// The transaction state comes from the status flags of the `SHOW` just read, and anything but `.idle`, `.unknown`
    /// included, keeps `autocommit` from committing a transaction that may be the user's.
    private func restoreSessionSettings(_ saved: [PluginSessionSetting]) async throws -> Bool {
        guard !saved.isEmpty else { return true }
        let current = try await readSessionSettings(saved.map(\.name))
        let isTransactionOpen = await sessionTransactionState() != .idle
        let restore = MySQLSessionScopePlan.restore(saved: saved, current: current, isTransactionOpen: isTransactionOpen)
        if !restore.isComplete {
            Self.logger.info("Left autocommit as the imported file set it, because the session holds an open transaction")
        }
        var firstFailure: Error?
        for statement in restore.statements {
            do {
                _ = try await executeSetup(statement)
            } catch {
                Self.logger.error(
                    "Could not put a session setting back with \(statement, privacy: .public): \(error.localizedDescription)"
                )
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw firstFailure
        }
        return restore.isComplete
    }

    private func restoreAfterFailedOpen(_ saved: [PluginSessionSetting]) async -> Bool {
        do {
            return try await restoreSessionSettings(saved)
        } catch {
            Self.logger.error("A session scope that failed to open could not put its settings back")
            return false
        }
    }
}
