//
//  TransactionEndingFlow.swift
//  TablePro
//

import AppKit
import Foundation

// Close, entry close and disconnect end a session that can hold a transaction: this asks how it ends first.
@MainActor
internal enum TransactionEndingFlow {
    internal enum Outcome: Equatable {
        case nothingOpen
        case ended
        case cancelled
    }

    // A database the read found holding one, and the tracked hold a commit goes through, if any.
    internal struct Entry: Equatable {
        let name: String
        let hold: SessionTransactionTracker.Hold?
    }

    internal static func resolve(
        connectionId: UUID,
        action: TransactionEndPrompt.Action,
        among databases: Set<String>? = nil,
        hasUnsavedWork: Bool = false,
        window: @MainActor () -> NSWindow?,
        databaseManager: DatabaseManager = .shared,
        ask: @MainActor (TransactionEndPrompt, NSWindow?) async -> AlertHelper.TransactionEndAnswer
            = AlertHelper.answerTransactionEnd(_:window:),
        commit: @MainActor ([SessionTransactionTracker.Hold]) async throws -> Bool
            = { try await ConnectionTransactionActions.commitBeforeEnding($0) },
        reportFailure: @MainActor (String, NSWindow?) -> Void = TransactionEndingFlow.showCommitFailure(_:window:)
    ) async -> Outcome {
        var parent: NSWindow?
        return await run(
            read: { await entries(for: connectionId, among: databases, in: databaseManager) },
            prompt: { entries in
                prompt(for: entries, action: action, connectionId: connectionId, hasUnsavedWork: hasUnsavedWork, in: databaseManager)
            },
            ask: { prompt in
                parent = window()
                return await ask(prompt, parent)
            },
            commit: commit,
            reportFailure: { reportFailure($0, parent) }
        )
    }

    // Roll Back sends nothing: ending the session rolls it back, and an explicit one would wait behind running work.
    // Each answer reads again, so a transaction opened meanwhile, or one a commit left open, is asked about too.
    internal static func run(
        read: @MainActor () async -> [Entry],
        prompt: @MainActor ([Entry]) -> TransactionEndPrompt?,
        ask: @MainActor (TransactionEndPrompt) async -> AlertHelper.TransactionEndAnswer,
        commit: @MainActor ([SessionTransactionTracker.Hold]) async throws -> Bool,
        reportFailure: @MainActor (String) -> Void
    ) async -> Outcome {
        var rolledBack: Set<String> = []
        var outcome = Outcome.nothingOpen
        while true {
            let entries = await read().filter { !rolledBack.contains($0.name) }
            guard let question = prompt(entries) else { return outcome }
            outcome = .ended
            switch await ask(question) {
            case .cancel:
                return .cancelled
            case .rollBack:
                rolledBack.formUnion(entries.map { $0.name })
            case .commit:
                do {
                    guard try await commit(entries.compactMap { $0.hold }) else { return .cancelled }
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    reportFailure(error.localizedDescription)
                    return .cancelled
                }
            }
        }
    }

    // Read fresh at every question: the answer to the one before can land after work opened or ended a transaction.
    internal static func entries(
        for connectionId: UUID,
        among databases: Set<String>?,
        in manager: DatabaseManager
    ) async -> [Entry] {
        let names = await manager.databasesHoldingTransaction(for: connectionId, among: databases)
        let browsed = manager.session(for: connectionId)?.resolvedBrowseDatabase ?? ""
        let holds = manager.sessionTransactions.holds(for: connectionId)
        return names.map { name in
            Entry(name: name, hold: holds.first { ($0.key.lane ?? browsed) == name })
        }
    }

    internal static func showCommitFailure(_ message: String, window: NSWindow?) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Could Not Commit the Transaction"),
            message: message,
            window: AlertHelper.resolveWindow(window).map(AlertOperationConfirming.frontmostSheet(of:))
        )
    }

    private static func prompt(
        for entries: [Entry],
        action: TransactionEndPrompt.Action,
        connectionId: UUID,
        hasUnsavedWork: Bool,
        in manager: DatabaseManager
    ) -> TransactionEndPrompt? {
        TransactionEndPrompt.make(
            action: action,
            names: entries.map { $0.name },
            holds: entries.compactMap { $0.hold },
            untracked: entries.contains { $0.hold == nil },
            savedUnderManualCommit: manager.commitMode(for: connectionId) == .manual,
            hasUnsavedWork: hasUnsavedWork,
            effectiveLevel: { ExecutionGateProvider.effectiveSafeModeLevel(for: $0, in: manager) },
            busy: { manager.isLaneBusy(holding: $0) }
        )
    }
}
