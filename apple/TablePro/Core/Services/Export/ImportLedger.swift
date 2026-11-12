//
//  ImportLedger.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ImportSessionState: Equatable, Sendable {
    case idle
    case open
    case aborted
    case unknown

    internal init(_ state: PluginSessionTransactionState) {
        switch state {
        case .idle, .holdsSessionLocks: self = .idle
        case .inTransaction: self = .open
        case .abortedTransaction: self = .aborted
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }

    internal var holdsTransaction: Bool { self == .open || self == .aborted }
}

internal enum ImportTableRollback: Equatable, Sendable {
    case transactional
    case nontransactional
    case unknown
}

internal struct ImportFileEffect: Equatable, Sendable {
    internal let index: Int
    internal let table: String?
    internal var rollback: ImportTableRollback = .unknown
    internal var submittedRows = 0
    internal var statements = 0
    internal var admittedWrite = false
    internal var failedWrite = false
    internal var deletedRows = false
}

internal struct ImportPreparationEffect: Equatable, Sendable {
    internal let table: TableScope
    internal let clearing: Bool
    internal var completed = false
    internal var fate = ImportFileFate.mayStay
}

internal struct ImportLedger: Equatable, Sendable {
    internal enum Holder: Equatable, Sendable {
        case none
        case joinedUser
        case owned
    }

    internal enum Ending: Equatable, Sendable {
        case committed
        case rolledBack
        case unknown
    }

    internal var holder = Holder.none
    internal var initialState = ImportSessionState.unknown
    internal var currentState = ImportSessionState.unknown
    internal var prepared = false
    internal var uncertainHistory = false
    internal var unseenStatements = false
    internal var ending: Ending?
    internal var effects: [Int: ImportFileEffect] = [:]
    internal var preparations: [UUID: ImportPreparationEffect] = [:]
    internal var errors: [String] = []
    internal var cleanupErrors: [String] = []

    internal var hasWrites: Bool { effects.values.contains { $0.admittedWrite } }

    internal mutating func observe(_ state: ImportSessionState, finalizing: Bool = false) {
        if finalizing, state != currentState {
            uncertainHistory = true
            if ending != nil { ending = .unknown }
        }
        if !finalizing {
            if state == .unknown || (currentState.holdsTransaction && state == .idle) {
                uncertainHistory = true
            }
            if holder == .none, state.holdsTransaction { uncertainHistory = true }
        }
        currentState = state
    }

    internal mutating func recordError(_ error: any Error) {
        let description = error.localizedDescription
        if errors.count < 1_000, !errors.contains(description) { errors.append(description) }
    }

    internal mutating func recordCleanupError(_ error: any Error) {
        let description = error.localizedDescription
        if !cleanupErrors.contains(description) { cleanupErrors.append(description) }
    }

    internal var canChooseCommit: Bool {
        hasWrites && holder == .owned && currentState == .open && ending == nil
            && !uncertainHistory && !unseenStatements
            && !hasUncertainEffects
    }

    private var hasUncertainEffects: Bool {
        effects.values.contains {
            $0.admittedWrite && (($0.rollback == .unknown && $0.table != nil)
                || ($0.failedWrite && $0.rollback == .nontransactional))
        }
    }

    internal var question: String { rowQuestion + preparationNote }

    private var rowQuestion: String {
        guard hasWrites else {
            return preparations.isEmpty ? String(localized: "Nothing has been imported yet.")
                : String(localized: "No rows from this run have been imported. Earlier table preparation is listed below.")
        }
        if uncertainHistory || unseenStatements || currentState == .unknown
            || hasUncertainEffects {
            return String(localized: "Anything already imported may stay.") + openTransactionNote
        }
        if holder != .owned, currentState.holdsTransaction {
            return (currentState == .aborted
                ? String(localized: "The open transaction failed. Roll it back yourself.")
                : String(localized: "The changes are in an open transaction on this connection. Commit or roll it back yourself."))
                + nontransactionalNote
        }
        if currentState == .aborted {
            return String(localized: "The import's transaction failed and can only be rolled back.") + nontransactionalNote
        }
        if canChooseCommit {
            return String(localized: "Choose whether to roll back or commit the import's open transaction.")
                + transactionalNote + nontransactionalNote + secondaryEffectsNote
        }
        switch ending {
        case .committed:
            return String(localized: "The import's transaction was already committed.") + nontransactionalNote
        case .rolledBack:
            return String(localized: "The import's transaction was already rolled back.") + nontransactionalNote
        case .unknown:
            return String(localized: "Anything already imported may stay.") + openTransactionNote
        case nil:
            return String(localized: "The statements already ran outside an import transaction. Their changes stay.")
                + secondaryEffectsNote
        }
    }

    internal var preparationNote: String {
        let lines = preparations.values.sorted { $0.table.table < $1.table.table }.map { effect in
            let action: String
            if effect.clearing {
                action = effect.completed ? String(localized: "table cleared before row import")
                    : String(localized: "table clearing failed before row import")
            } else {
                action = effect.completed ? String(localized: "table creation completed before row import")
                    : String(localized: "table creation failed before row import")
            }
            var fate = effect.fate
            if fate == .openTransaction || fate == .abortedTransaction {
                if currentState == .aborted { fate = .abortedTransaction } else if currentState != .open || uncertainHistory { fate = .mayStay }
            }
            return String(format: String(localized: "%1$@: %2$@, %3$@."), effect.table.table, action, fate.text)
        }
        return lines.isEmpty ? "" : "\n\n" + lines.joined(separator: "\n")
    }

    internal var openTransactionNote: String {
        guard currentState.holdsTransaction else { return "" }
        return "\n\n" + (currentState == .aborted
            ? String(localized: "The open transaction failed. Roll it back on this connection.")
            : String(localized: "A transaction is still open on this connection. Commit or roll it back."))
    }

    private var transactionalNote: String {
        let tables = tableNames(for: .transactional)
        guard !tables.isEmpty else { return "" }
        return "\n\n" + String(format: String(localized: "Direct changes to %@ are in that transaction."), tables)
    }

    private var nontransactionalNote: String {
        let tables = tableNames(for: .nontransactional)
        guard !tables.isEmpty else { return "" }
        return "\n\n" + String(format: String(localized: "Changes to %@ cannot roll back and stay either way."), tables)
    }

    private var secondaryEffectsNote: String {
        "\n\n" + String(localized: "Changes a rollback cannot undo stay either way.")
    }

    private func tableNames(for rollback: ImportTableRollback) -> String {
        let names = Set(effects.values.filter { $0.admittedWrite && $0.rollback == rollback }.compactMap(\.table))
        return ListFormatter.localizedString(byJoining: names.sorted())
    }
}

internal struct ImportStopQuestion: Equatable, Identifiable, Sendable {
    internal let generation: Int
    internal let ledger: ImportLedger
    internal var id: Int { generation }
}

internal enum ImportFileFate: Equatable, Sendable {
    case notImported
    case mayStay
    case kept
    case committed
    case rolledBack
    case openTransaction
    case abortedTransaction

    internal var text: String {
        switch self {
        case .notImported: return String(localized: "not imported")
        case .mayStay: return String(localized: "changes may stay")
        case .kept: return String(localized: "changes kept")
        case .committed: return String(localized: "changes committed")
        case .rolledBack: return String(localized: "direct changes rolled back")
        case .openTransaction: return String(localized: "changes are in the open transaction")
        case .abortedTransaction: return String(localized: "the transaction failed and needs rollback")
        }
    }
}

internal struct ImportStopResult: Equatable, Sendable {
    internal let ledger: ImportLedger

    internal func fate(for index: Int) -> ImportFileFate {
        guard let effect = ledger.effects[index], effect.admittedWrite else { return .notImported }
        if ledger.uncertainHistory || ledger.unseenStatements || effect.rollback == .unknown
            || (effect.failedWrite && effect.rollback == .nontransactional) {
            return .mayStay
        }
        if effect.rollback == .nontransactional { return .kept }
        if ledger.holder == .owned {
            switch ledger.ending {
            case .rolledBack: return .rolledBack
            case .committed: return .committed
            case .unknown: return .mayStay
            case nil: break
            }
        }
        if ledger.holder != .owned, ledger.currentState.holdsTransaction {
            return ledger.currentState == .aborted ? .abortedTransaction : .openTransaction
        }
        if ledger.holder == .none, ledger.currentState == .idle { return .kept }
        return .mayStay
    }

    internal func fileText(for index: Int) -> String {
        guard let effect = ledger.effects[index] else { return ImportFileFate.notImported.text }
        let count: String
        if effect.table == nil {
            count = effect.statements == 1 ? String(localized: "1 statement completed.")
                : String(format: String(localized: "%lld statements completed."), Int64(effect.statements))
        } else {
            count = effect.submittedRows == 1 ? String(localized: "1 row submitted in a completed write.")
                : String(format: String(localized: "%lld rows submitted in completed writes."), Int64(effect.submittedRows))
        }
        let fate = fate(for: index)
        let outcome: String
        if effect.table == nil, fate == .rolledBack {
            outcome = String(localized: "the import's transaction was rolled back")
        } else if effect.table == nil, fate == .committed {
            outcome = String(localized: "the import's transaction was committed")
        } else {
            outcome = fate.text
        }
        var parts = [count, outcome]
        if effect.deletedRows { parts.append(String(localized: "The table was emptied before importing rows.")) }
        if effect.failedWrite {
            parts.append(String(localized: "A failed write may have made additional changes."))
        }
        return parts.joined(separator: " ")
    }

    internal var completionNotes: String {
        ([ledger.openTransactionNote.trimmingCharacters(in: .whitespacesAndNewlines)] + ledger.cleanupErrors)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    internal var failureText: String {
        let shown = ledger.cleanupErrors + ledger.errors.prefix(3).filter { !ledger.cleanupErrors.contains($0) }
        var text = shown.joined(separator: "\n")
        if ledger.errors.count > 3 {
            text += "\n" + String(
                format: String(localized: "%lld additional errors are in Copy Details."),
                Int64(ledger.errors.count - 3)
            )
        }
        return text
    }

    internal var details: String {
        text + "\n\n" + (ledger.cleanupErrors + ledger.errors).joined(separator: "\n")
    }

    internal var text: String {
        var parts = ledger.effects.keys.sorted().map { index in
            let detail = fileText(for: index)
            guard let table = ledger.effects[index]?.table else { return detail }
            return String(format: String(localized: "%1$@: %2$@"), table, detail)
        }
        if parts.isEmpty, ledger.preparations.isEmpty { parts.append(String(localized: "Nothing was imported.")) }
        if !ledger.preparationNote.isEmpty { parts.append(ledger.preparationNote.trimmingCharacters(in: .whitespacesAndNewlines)) }
        parts.append(String(localized: "Changes a rollback cannot undo stay either way."))
        if !ledger.openTransactionNote.isEmpty { parts.append(ledger.openTransactionNote.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if !failureText.isEmpty { parts.append(failureText) }
        return parts.joined(separator: "\n\n")
    }
}
