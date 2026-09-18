//
//  AIChatToolUseBlockView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct AIChatToolUseBlockView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let block: ToolUseBlock

    @State private var isExpanded: Bool = false

    @Environment(\.chatApprovalConnectionName) private var connectionName

    private var isPending: Bool {
        if case .pending = block.approvalState { return true }
        return false
    }

    private var shouldShowInput: Bool {
        hasInput && (isExpanded || (isPending && proposedStatement == nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasInput else { return }
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.adjustable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(callingLabel)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(block.name)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    if hasInput {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)

            if isPending, let proposedStatement {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(proposedStatement)
                        .font(themeEngine.valueFontSwiftUI)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .accessibilityLabel(String(localized: "Proposed statement"))
                .accessibilityValue(proposedStatement)
            }

            if isPending {
                Text(targetDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(localized: "Runs against"))
                    .accessibilityValue(targetDescription)
            }

            if shouldShowInput {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(prettyInput)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            if case .pending = block.approvalState {
                ToolApprovalActionsRow(
                    toolUseId: block.id,
                    toolName: block.name,
                    allowsStandingGrant: allowsStandingGrant,
                    standingGrantUnavailableReason: standingGrantUnavailableReason
                )
            }
        }
        .padding(.horizontal, 8)
    }

    /// A destructive statement is confirmed every time it is proposed. No standing grant, no Safe
    /// Mode level and no earlier answer covers the next one.
    private var allowsStandingGrant: Bool {
        ChatToolRegistry.shared.tool(named: block.name)?.mode != .agentOnly
    }

    private var standingGrantUnavailableReason: String? {
        guard !allowsStandingGrant else { return nil }
        return String(localized: "Confirmed each time.")
    }

    /// Where the statement will run.
    ///
    /// The card used to print the model's whole input, which happened to include the `database` it
    /// named. Showing the statement alone read better and hid the one field most able to surprise:
    /// a model can name a database the user is not looking at, and an explicit Run pre-clears the
    /// execution gate, whose own dialog names only the connection. So the target is spelled out
    /// here, and the full input stays one click away.
    private var targetDescription: String {
        var parts: [String] = []
        if let connectionName { parts.append(connectionName) }
        if case .object(let fields) = block.input {
            if case .string(let database)? = fields["database"], !database.isEmpty {
                parts.append(database)
            }
            if case .string(let schema)? = fields["schema"], !schema.isEmpty {
                parts.append(schema)
            }
        }
        guard !parts.isEmpty else {
            return String(localized: "Runs against this connection's current database.")
        }
        return String(
            format: String(localized: "Runs against %@"),
            parts.joined(separator: " / ")
        )
    }

    /// The statement itself, when the call carries one, so the user answers about SQL rather than
    /// about a tool name with a JSON blob under it. The whole input stays behind the disclosure.
    private var proposedStatement: String? {
        guard case .object(let fields) = block.input,
              case .string(let query)? = fields["query"],
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return query
    }

    private var callingLabel: String {
        switch block.approvalState {
        case .pending:   return String(localized: "Pending approval for")
        case .cancelled: return String(localized: "Cancelled")
        case .denied:    return String(localized: "Blocked")
        case .approved:  return String(localized: "Calling")
        }
    }

    private var hasInput: Bool {
        switch block.input {
        case .object(let dict): return !dict.isEmpty
        case .array(let array): return !array.isEmpty
        case .null: return false
        default: return true
        }
    }

    private var prettyInput: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(block.input),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
