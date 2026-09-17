//
//  AIChatToolUseBlockView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct AIChatToolUseBlockView: View {
    let block: ToolUseBlock

    @State private var isExpanded: Bool = false

    private var isPending: Bool {
        if case .pending = block.approvalState { return true }
        return false
    }

    private var shouldShowInput: Bool {
        hasInput && (isExpanded || isPending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasInput, !isPending else { return }
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
                    if hasInput && !isPending {
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
                        .font(ThemeEngine.shared.valueFontSwiftUI)
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
            } else if shouldShowInput {
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
