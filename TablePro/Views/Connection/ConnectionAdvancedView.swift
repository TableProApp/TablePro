//
//  ConnectionAdvancedView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 31/3/26.
//

import SwiftUI
import TableProPluginKit

struct ConnectionAdvancedView: View {
    @Binding var additionalFieldValues: [String: String]
    @Binding var startupCommands: String
    @Binding var preConnectScript: String
    @Binding var aiPolicy: AIConnectionPolicy?

    let databaseType: DatabaseType
    let additionalConnectionFields: [ConnectionField]

    var body: some View {
        Form {
            let advancedFields = additionalConnectionFields.filter { $0.section == .advanced }
            if !advancedFields.isEmpty {
                Section(databaseType.displayName) {
                    ForEach(advancedFields, id: \.id) { field in
                        if isFieldVisible(field) {
                            ConnectionFieldRow(
                                field: field,
                                value: Binding(
                                    get: {
                                        additionalFieldValues[field.id]
                                            ?? field.defaultValue ?? ""
                                    },
                                    set: { additionalFieldValues[field.id] = $0 }
                                )
                            )
                        }
                    }
                }
            }

            Section(String(localized: "Startup Commands")) {
                StartupCommandsEditor(text: $startupCommands)
                    .frame(height: 80)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text(
                    "SQL commands to run after connecting, e.g. SET time_zone = 'Asia/Ho_Chi_Minh'. One per line or separated by semicolons."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "Pre-Connect Script")) {
                StartupCommandsEditor(text: $preConnectScript)
                    .frame(height: 80)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text(
                    "Shell script to run before connecting. Non-zero exit aborts connection."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if AppSettingsManager.shared.ai.enabled {
                Section(String(localized: "AI")) {
                    Picker(String(localized: "AI Policy"), selection: $aiPolicy) {
                        Text(String(localized: "Use Default"))
                            .tag(AIConnectionPolicy?.none as AIConnectionPolicy?)
                        ForEach(AIConnectionPolicy.allCases) { policy in
                            Text(policy.displayName)
                                .tag(AIConnectionPolicy?.some(policy) as AIConnectionPolicy?)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func isFieldVisible(_ field: ConnectionField) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        let currentValue = additionalFieldValues[rule.fieldId] ?? defaultFieldValue(rule.fieldId)
        return rule.values.contains(currentValue)
    }

    private func defaultFieldValue(_ fieldId: String) -> String {
        additionalConnectionFields.first { $0.id == fieldId }?.defaultValue ?? ""
    }
}

// MARK: - Startup Commands Editor

struct StartupCommandsEditor: NSViewRepresentable {
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
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.drawsBackground = false
        textView.delegate = context.coordinator

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

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
