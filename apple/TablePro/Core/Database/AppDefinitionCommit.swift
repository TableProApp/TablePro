//
//  AppDefinitionCommit.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Refused before anything ran, so an external caller reads it as it is.
internal struct DefinitionInOpenTransactionRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? {
        String(
            localized: "A transaction is open on this connection, and this change would have to end it. Commit or roll back the transaction, then try again."
        )
    }
}

// One statement the app runs with no BEGIN of its own; a Teradata ANSI session keeps it pending until a COMMIT.
internal enum AppDefinitionCommit {
    internal static func run<T>(
        family: TransactionEngineFamily,
        refusesOpenTransaction: Bool,
        readState: () async -> PluginSessionTransactionState,
        commit: @escaping @Sendable () async throws -> Void,
        rollback: @escaping @Sendable () async throws -> Void,
        body: () async throws -> T
    ) async throws -> T {
        guard family.unwrappedWorkStaysOpen else { return try await body() }
        let before = await readState()
        if refusesOpenTransaction, before.holdsUserTransaction {
            throw DefinitionInOpenTransactionRefusal()
        }
        do {
            let value = try await body()
            try await commitIfOpen(family: family, readState: readState, commit: commit)
            return value
        } catch {
            // Teradata keeps a failed request's locks until the transaction ends.
            if before == .idle {
                _ = try? await TaskCancellationShield.run(rollback)
            }
            throw error
        }
    }

    internal static func commitIfOpen(
        family: TransactionEngineFamily,
        readState: () async -> PluginSessionTransactionState,
        commit: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard family.unwrappedWorkStaysOpen, await readState() == .inTransaction else { return }
        // The work it ends has already run, so a cancelled task must not refuse it.
        try await TaskCancellationShield.run(commit)
    }
}

extension AppDefinitionCommit {
    internal static func run<T>(
        on driver: DatabaseDriver,
        refusesOpenTransaction: Bool,
        body: () async throws -> T
    ) async throws -> T {
        try await run(
            family: TransactionEngineFamily.of(driver.connection.type),
            refusesOpenTransaction: refusesOpenTransaction,
            readState: { await driver.heldSessionTransactionState() },
            commit: { try await driver.commitTransaction() },
            rollback: { try await driver.rollbackTransaction() },
            body: body
        )
    }

    internal static func run<T>(
        on driver: any PluginDatabaseDriver,
        family: TransactionEngineFamily,
        refusesOpenTransaction: Bool,
        body: () async throws -> T
    ) async throws -> T {
        try await run(
            family: family,
            refusesOpenTransaction: refusesOpenTransaction,
            readState: { await Self.heldState(of: driver) },
            commit: { try await driver.commitTransaction() },
            rollback: { try await driver.rollbackTransaction() },
            body: body
        )
    }

    internal static func commitIfOpen(on driver: any PluginDatabaseDriver, family: TransactionEngineFamily) async throws {
        try await commitIfOpen(
            family: family,
            readState: { await Self.heldState(of: driver) },
            commit: { try await driver.commitTransaction() }
        )
    }

    private static func heldState(of driver: any PluginDatabaseDriver) async -> PluginSessionTransactionState {
        guard driver.supportsTransactions else { return .unknown }
        return await driver.sessionTransactionState()
    }
}
