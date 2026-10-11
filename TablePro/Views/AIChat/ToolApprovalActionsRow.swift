//
//  ToolApprovalActionsRow.swift
//  TablePro
//

import SwiftUI

/// The answer to one proposed tool call.
///
/// The verb is **Reject**, not Cancel. The user did not start this operation, the assistant
/// proposed it, and Cancel on macOS means abandoning something you began. Reject is also the state
/// the transcript records, so the button and the state it produces now agree.
///
/// Only the first card still waiting takes Return and Escape. Every card used to carry both, so
/// with two proposals on screen the keyboard answered an arbitrary one.
struct ToolApprovalActionsRow: View {
    let toolUseId: String
    let toolName: String
    /// Whether a standing grant may be recorded for this call. A destructive statement is confirmed
    /// on its own every time, and so is every write while a Safe Mode floor is in force.
    var allowsStandingGrant: Bool = true
    var standingGrantUnavailableReason: String?

    @Environment(\.chatPrimaryPendingToolUseId) private var primaryPendingToolUseId
    @Environment(\.chatApprovalConnectionName) private var connectionName
    @Environment(\.chatApprovalSessionId) private var sessionId

    private var takesDefaultAction: Bool {
        primaryPendingToolUseId == toolUseId
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                resolve(.run)
            } label: {
                Text(String(localized: "Run"))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(takesDefaultAction ? .defaultAction : nil)
            .accessibilityLabel(runLabel)

            if allowsStandingGrant {
                Button {
                    resolve(.alwaysAllow)
                } label: {
                    Text(String(localized: "Always Allow"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(alwaysAllowHelp)
                .accessibilityLabel(alwaysAllowHelp)
            }

            Button {
                resolve(.cancel)
            } label: {
                Text(String(localized: "Reject"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(takesDefaultAction ? .cancelAction : nil)
            .accessibilityLabel(rejectLabel)

            if !allowsStandingGrant, let standingGrantUnavailableReason {
                Text(standingGrantUnavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.top, 2)
    }

    private func resolve(_ decision: ToolApprovalDecision) {
        guard let sessionId else { return }
        ToolApprovalCenter.shared.resolve(sessionId: sessionId, toolUseId: toolUseId, decision: decision)
    }

    /// Each button names its own call. A turn proposing three writes otherwise hands assistive
    /// clients three identical "Run" buttons with nothing to tell them apart, and Run is the one
    /// that executes the statement.
    private var runLabel: String {
        String(format: String(localized: "Run %@"), toolName)
    }

    private var rejectLabel: String {
        String(format: String(localized: "Reject %@"), toolName)
    }

    private var alwaysAllowHelp: String {
        guard let connectionName else {
            return String(format: String(localized: "Always allow %@ for this connection"), toolName)
        }
        return String(format: String(localized: "Always allow %1$@ on %2$@"), toolName, connectionName)
    }
}
