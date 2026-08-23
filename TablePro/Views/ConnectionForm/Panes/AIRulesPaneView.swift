//
//  AIRulesPaneView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct AIRulesPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Form {
            Section {
                AIRulesEditor(text: $coordinator.aiRules.rules)
                    .frame(minHeight: 280)
            } header: {
                Text(String(localized: "Rules"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // swiftlint:disable:next line_length
                    Text("Custom guidance the AI sees on every chat turn for this connection. Use it for table conventions, naming, columns to avoid (PII, soft-deleted rows), join hints, or business rules the schema doesn't show.")
                    Text(String(localized: "Plain text. Markdown is preserved as written."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                // swiftlint:disable:next line_length
                Text(verbatim: "- Tables prefixed with `tmp_` are scratch and safe to ignore\n- `users.email_hash` is the join key, not `users.email`\n- Always filter `orders` by `deleted_at IS NULL`\n- Never select `users.ssn`")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } header: {
                Text(String(localized: "Examples"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct AIRulesEditor: View {
    @Binding var text: String

    var body: some View {
        TextValueEditor(
            text: $text,
            font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            borderType: .bezelBorder,
            movesFocusOnTab: true
        )
    }
}
