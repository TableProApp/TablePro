//
//  AgentSessionConfirmation.swift
//  TablePro
//

import Foundation

/// What a session command asks before it runs.
///
/// Deleting always asks, because it throws the conversation away. Closing asks only of a session that
/// is busy: an idle one loses nothing by stopping and keeps its conversation in the rail, while one
/// in the middle of a reply, or waiting on an answer about a statement, has that cut off. What the
/// session is doing is what the question says, since it is the part the person may not have seen:
/// the command can come from the menu bar with the session off screen.
///
/// Each message is one whole sentence pair rather than a busy clause joined to a common one, because
/// a translation cannot be assembled from parts that were joined by a space in English.
internal struct AgentSessionConfirmation: Equatable {
    internal let title: String
    internal let message: String
    internal let confirmButton: String
    /// Only deleting destroys anything, so only deleting takes Return off the confirming button.
    internal let isDestructive: Bool

    /// Nil for a session that is not busy, which closes without a question.
    internal static func close(_ sessionTitle: String, status: AgentSessionStatus) -> AgentSessionConfirmation? {
        let message: String
        switch Activity(status) {
        case .working?:
            message = String(
                localized: "The session is still working. Closing it stops the reply, and its conversation stays in the list."
            )
        case .waitingOnYou?:
            message = String(
                localized: "The session is waiting on your answer about a statement. Closing it cancels the statement, and its conversation stays in the list."
            )
        case nil:
            return nil
        }
        return AgentSessionConfirmation(
            title: String(format: String(localized: "Close “%@”?"), sessionTitle),
            message: message,
            confirmButton: String(localized: "Close Session"),
            isDestructive: false
        )
    }

    internal static func delete(_ sessionTitle: String, status: AgentSessionStatus) -> AgentSessionConfirmation {
        let message: String
        switch Activity(status) {
        case .working?:
            message = String(
                localized: "The session is still working. Deleting it stops the reply and deletes its conversation, which can't be restored."
            )
        case .waitingOnYou?:
            message = String(
                localized: "The session is waiting on your answer about a statement. Deleting it cancels the statement and deletes its conversation, which can't be restored."
            )
        case nil:
            message = String(localized: "The session and its conversation are deleted, and can't be restored.")
        }
        return AgentSessionConfirmation(
            title: String(format: String(localized: "Delete “%@”?"), sessionTitle),
            message: message,
            confirmButton: String(localized: "Delete"),
            isDestructive: true
        )
    }

    /// What a busy session is doing, which is what ending it cuts off.
    private enum Activity {
        case working
        case waitingOnYou

        init?(_ status: AgentSessionStatus) {
            guard status.isBusy else { return nil }
            self = status == .waitingOnYou ? .waitingOnYou : .working
        }
    }
}
