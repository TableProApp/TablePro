//
//  ChatApprovalEnvironment.swift
//  TablePro
//

import SwiftUI

/// What an approval card needs to know that only the transcript can answer.
///
/// A card is drawn per tool-use block and knows nothing about the conversation around it, but three
/// of its decisions are about that conversation: which card Return belongs to, which connection the
/// answer is about, and which session it belongs to. All three are set once by the panel that owns
/// the transcript.
internal extension EnvironmentValues {
    /// The only waiting card that may claim Return and Escape.
    ///
    /// A turn can propose several writes, and every card used to carry `.defaultAction` and
    /// `.cancelAction`, so Return answered whichever button AppKit reached first. Handing the
    /// shortcut to one card is what `keyboardShortcut(_:)`'s optional overload is for.
    @Entry var chatPrimaryPendingToolUseId: String?

    /// The connection the conversation is attached to, named on the card so the user is answering
    /// about a database rather than about a tool.
    @Entry var chatApprovalConnectionName: String?

    /// Which session a card's answer belongs to. Two sessions can both be waiting on a call the
    /// provider numbered `call_0`, so the answer has to name the session as well as the call.
    @Entry var chatApprovalSessionId: UUID?
}
