//
//  ToolApprovalActionsRow.swift
//  TablePro
//

import SwiftUI

struct ToolApprovalActionsRow: View {
    let toolUseId: String
    let toolName: String

    @Environment(\.chatSessionId) private var sessionId
    @Environment(\.chatWriteFloorActive) private var writeFloorActive
    @Environment(\.chatPrimaryPendingToolUseId) private var primaryPendingToolUseId

    /// Only the first waiting call takes `Return`. Every row carried the default action before, so
    /// three proposed writes gave the window three default buttons at once.
    private var isPrimary: Bool { primaryPendingToolUseId == toolUseId }

    /// Nil means the row cannot say which session's approval it would resolve, so it resolves
    /// nothing. Disabling is the only safe answer: a decision sent under the wrong session id would
    /// run one session's statement on another session's click.
    private var request: ApprovalRequestID? {
        guard let sessionId else { return nil }
        return ApprovalRequestID(sessionId: sessionId, toolUseId: toolUseId)
    }

    /// Every button names the tool it would act on.
    ///
    /// A turn that proposes three writes puts three of these rows in the transcript, and without the
    /// name VoiceOver and Voice Control both see three buttons called "Run" with nothing to tell
    /// them apart: "click Run" is ambiguous and the rotor lists the same word three times. The
    /// visible title stays the verb, which is what a reader looking at the card beside it needs.
    var body: some View {
        HStack(spacing: 8) {
            Button {
                resolve(.run)
            } label: {
                Text(String(localized: "Run"))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(isPrimary ? .defaultAction : nil)
            .accessibilityLabel(String(format: String(localized: "Run %@"), toolName))

            Button {
                resolve(.alwaysAllow)
            } label: {
                Text(String(localized: "Always for this connection"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(writeFloorActive)
            .help(
                writeFloorActive
                    ? String(
                        localized: "Not available while a Safe Mode floor is in force. Each write is confirmed on its own."
                    )
                    : String(format: String(localized: "Always allow %@ for this connection"), toolName)
            )

            Button {
                resolve(.cancel)
            } label: {
                Text(String(localized: "Cancel"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(isPrimary ? .cancelAction : nil)
            .accessibilityLabel(String(format: String(localized: "Cancel %@"), toolName))

            Spacer()
        }
        .padding(.top, 2)
        .disabled(request == nil)
    }

    private func resolve(_ decision: ToolApprovalDecision) {
        guard let request else { return }
        ToolApprovalCenter.shared.resolve(request, decision: decision)
    }
}
