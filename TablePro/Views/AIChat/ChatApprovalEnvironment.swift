//
//  ChatApprovalEnvironment.swift
//  TablePro
//

import SwiftUI

/// What an approval card needs to know that only the transcript can answer.
///
/// A card is drawn per tool-use block and knows nothing about the conversation around it, but two
/// of its decisions are about that conversation: which card Return belongs to, and which connection
/// the answer is about. Both are set once by the panel that owns the transcript.
private struct ChatPrimaryPendingToolUseIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct ChatApprovalConnectionNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The only waiting card that may claim Return and Escape.
    ///
    /// A turn can propose several writes, and every card used to carry `.defaultAction` and
    /// `.cancelAction`, so Return answered whichever button AppKit reached first. Handing the
    /// shortcut to one card is what `keyboardShortcut(_:)`'s optional overload is for.
    var chatPrimaryPendingToolUseId: String? {
        get { self[ChatPrimaryPendingToolUseIdKey.self] }
        set { self[ChatPrimaryPendingToolUseIdKey.self] = newValue }
    }

    /// The connection the conversation is attached to, named on the card so the user is answering
    /// about a database rather than about a tool.
    var chatApprovalConnectionName: String? {
        get { self[ChatApprovalConnectionNameKey.self] }
        set { self[ChatApprovalConnectionNameKey.self] = newValue }
    }
}
