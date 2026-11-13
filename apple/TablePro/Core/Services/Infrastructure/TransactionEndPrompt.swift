//
//  TransactionEndPrompt.swift
//  TablePro
//

import Foundation

// What closing, disconnecting, quitting or relaunching asks about an open transaction it would end.
internal struct TransactionEndPrompt: Equatable, Sendable {
    internal enum Action: Equatable, Sendable {
        case closeEntry(database: String)
        case closeConnection(name: String)
        case disconnect(name: String)
        case quit
        case relaunch

        var followsSavePrompt: Bool {
            switch self {
            case .closeEntry, .closeConnection: return true
            case .disconnect, .quit, .relaunch: return false
            }
        }
    }

    internal enum CommitBlock: Equatable, Sendable {
        case aborted
        case readOnly
        case busy
        // A database the live read found holding one, with no tracked hold to commit through.
        case untracked
    }

    internal let title: String
    internal let message: String
    internal let commitBlock: CommitBlock?
    // The roll-back alert's confirming button, shown when Commit is not offered.
    internal let confirmButton: String

    internal var offersCommit: Bool { commitBlock == nil }

    // A failed transaction can never commit, so it is named before the reasons that pass. `effectiveLevel` is the
    // gate's level per connection, so the bar, the menu and this alert offer Commit by the same rule.
    internal static func commitBlock(
        holds: [SessionTransactionTracker.Hold],
        untracked: Bool,
        effectiveLevel: (UUID) -> SafeModeLevel,
        busy: (SessionTransactionTracker.Hold) -> Bool
    ) -> CommitBlock? {
        if holds.contains(where: { $0.state == .aborted }) { return .aborted }
        let refused = holds.contains { hold in
            !ConnectionTransactionActions.offersCommit(hold.state, effectiveLevel: effectiveLevel(hold.connectionId))
        }
        if refused { return .readOnly }
        if holds.contains(where: { busy($0) }) { return .busy }
        if untracked || holds.isEmpty { return .untracked }
        return nil
    }

    // Nil when nothing holds a transaction. `names` are databases, or connections for quit and relaunch.
    internal static func make(
        action: Action,
        names: [String],
        holds: [SessionTransactionTracker.Hold],
        untracked: Bool = false,
        savedUnderManualCommit: Bool = false,
        hasUnsavedWork: Bool = false,
        effectiveLevel: (UUID) -> SafeModeLevel,
        busy: (SessionTransactionTracker.Hold) -> Bool
    ) -> TransactionEndPrompt? {
        guard !names.isEmpty else { return nil }
        let block = commitBlock(holds: holds, untracked: untracked, effectiveLevel: effectiveLevel, busy: busy)
        let several = max(names.count, holds.count) > 1
        var paragraphs: [String]
        if block == nil {
            paragraphs = [commitLead(action, names: names, holds: holds)]
        } else {
            paragraphs = [rollBackLead(action, names: names, holds: holds)]
            if let reason = block.flatMap(reason(for:)) {
                paragraphs.append(reason)
            }
        }
        // Only a close asked Save first, so only there can the transaction hold edits the user just saved.
        if savedUnderManualCommit, action.followsSavePrompt {
            paragraphs.append(String(localized: "Edits saved with Manual Commit on are not committed yet."))
        }
        if hasUnsavedWork, let line = unsavedLine(for: action) {
            paragraphs.append(line)
        }
        return TransactionEndPrompt(
            title: block == nil ? commitTitle(action, several: several) : rollBackTitle(action),
            message: paragraphs.joined(separator: "\n\n"),
            commitBlock: block,
            confirmButton: rollBackButton(action)
        )
    }

    private static func quoted(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })
    }

    private static func commitTitle(_ action: Action, several: Bool) -> String {
        switch action {
        case .closeEntry(let database):
            return String(
                format: String(localized: "Do you want to commit the open transaction before closing the database “%@”?"),
                database
            )
        case .closeConnection(let name):
            return String(
                format: several
                    ? String(localized: "Do you want to commit the open transactions before closing “%@”?")
                    : String(localized: "Do you want to commit the open transaction before closing “%@”?"),
                name
            )
        case .disconnect(let name):
            return String(
                format: several
                    ? String(localized: "Do you want to commit the open transactions before disconnecting from “%@”?")
                    : String(localized: "Do you want to commit the open transaction before disconnecting from “%@”?"),
                name
            )
        case .quit:
            return several
                ? String(localized: "Do you want to commit the open transactions before quitting?")
                : String(localized: "Do you want to commit the open transaction before quitting?")
        case .relaunch:
            return several
                ? String(localized: "Do you want to commit the open transactions before relaunching?")
                : String(localized: "Do you want to commit the open transaction before relaunching?")
        }
    }

    private static func commitLead(_ action: Action, names: [String], holds: [SessionTransactionTracker.Hold]) -> String {
        switch action {
        case .closeEntry:
            return String(localized: "Changes you don’t commit are rolled back.")
        case .closeConnection, .disconnect:
            // One session for every database: the title names the connection, and its database can be a file path.
            if names.count == 1, holds.allSatisfy({ $0.key.lane == nil }) {
                return String(localized: "Changes you don’t commit are rolled back.")
            }
            guard names.count > 1 else {
                return String(
                    format: String(localized: "The database “%@” has an open transaction. Changes you don’t commit are rolled back."),
                    names[0]
                )
            }
            return String(
                format: String(localized: "These databases have open transactions: %@. Changes you don’t commit are rolled back."),
                quoted(names)
            )
        case .quit, .relaunch:
            if names.count > 1 {
                return String(
                    format: String(localized: "These connections have open transactions: %@. Changes you don’t commit are rolled back."),
                    quoted(names)
                )
            }
            return String(
                format: holds.count > 1
                    ? String(localized: "The connection “%@” has open transactions. Changes you don’t commit are rolled back.")
                    : String(localized: "The connection “%@” has an open transaction. Changes you don’t commit are rolled back."),
                names[0]
            )
        }
    }

    private static func rollBackTitle(_ action: Action) -> String {
        switch action {
        case .closeEntry(let database):
            return String(format: String(localized: "Close the database “%@”?"), database)
        case .closeConnection(let name):
            return String(format: String(localized: "Close the connection “%@”?"), name)
        case .disconnect(let name):
            return String(format: String(localized: "Disconnect from “%@”?"), name)
        case .quit:
            return String(localized: "Quit with an Open Transaction?")
        case .relaunch:
            return String(localized: "Relaunch with an Open Transaction?")
        }
    }

    private static func rollBackLead(_ action: Action, names: [String], holds: [SessionTransactionTracker.Hold]) -> String {
        let several = names.count > 1
        let oneSession = !several && !holds.isEmpty && holds.allSatisfy { $0.key.lane == nil }
        switch action {
        case .closeConnection where oneSession:
            return String(localized: "This connection has an open transaction. Closing rolls it back and discards its uncommitted changes.")
        case .disconnect where oneSession:
            return String(
                localized: "This connection has an open transaction. Disconnecting rolls it back and discards its uncommitted changes."
            )
        case .closeEntry:
            return String(
                localized: "This database has an open transaction. Closing it rolls the transaction back and discards its uncommitted changes."
            )
        case .closeConnection:
            return several
                ? String(
                    format: String(localized: "These databases have open transactions: %@. Closing rolls them back and discards their uncommitted changes."),
                    quoted(names)
                )
                : String(
                    format: String(localized: "The database “%@” has an open transaction. Closing rolls it back and discards its uncommitted changes."),
                    names[0]
                )
        case .disconnect:
            return several
                ? String(
                    format: String(localized: "These databases have open transactions: %@. Disconnecting rolls them back and discards their uncommitted changes."),
                    quoted(names)
                )
                : String(
                    format: String(localized: "The database “%@” has an open transaction. Disconnecting rolls it back and discards its uncommitted changes."),
                    names[0]
                )
        case .quit:
            return several
                ? String(format: String(localized: "Uncommitted changes on %@ are rolled back when TablePro quits."), quoted(names))
                : String(format: String(localized: "Uncommitted changes on “%@” are rolled back when TablePro quits."), names[0])
        case .relaunch:
            return several
                ? String(format: String(localized: "Uncommitted changes on %@ are rolled back when TablePro relaunches."), quoted(names))
                : String(format: String(localized: "Uncommitted changes on “%@” are rolled back when TablePro relaunches."), names[0])
        }
    }

    private static func reason(for block: CommitBlock) -> String? {
        switch block {
        case .aborted:
            return String(localized: "A statement failed in the transaction, so it can only be rolled back.")
        case .readOnly:
            return String(localized: "Read-Only Safe Mode does not allow a commit.")
        case .busy:
            return String(localized: "A statement is still running in the transaction, so it cannot be committed now.")
        case .untracked:
            return nil
        }
    }

    // A close asks about unsaved work on its own Save alert first, so only these carry it here.
    private static func unsavedLine(for action: Action) -> String? {
        switch action {
        case .disconnect:
            return String(localized: "Unsaved changes will be lost.")
        case .quit:
            return String(localized: "Some tabs have unsaved edits. Quitting will discard these changes.")
        case .relaunch:
            return String(localized: "Some tabs have unsaved edits. Relaunching will discard these changes.")
        case .closeEntry, .closeConnection:
            return nil
        }
    }

    private static func rollBackButton(_ action: Action) -> String {
        switch action {
        case .closeEntry, .closeConnection: return String(localized: "Close")
        case .disconnect: return String(localized: "Disconnect")
        case .quit: return String(localized: "Quit Anyway")
        case .relaunch: return String(localized: "Relaunch Anyway")
        }
    }
}
