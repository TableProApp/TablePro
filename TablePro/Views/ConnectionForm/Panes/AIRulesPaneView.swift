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

private struct AIRulesEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false
        textView.string = text
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator

        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
