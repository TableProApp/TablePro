//
//  PluginDiagnosticSheet.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

struct PluginDiagnosticItem: Identifiable, Equatable {
    let id = UUID()
    let diagnostic: PluginDiagnostic
    let connectionTarget: String
    let username: String

    @MainActor
    static func classify(
        error: Error,
        connection: DatabaseConnection,
        username: String
    ) -> PluginDiagnosticItem? {
        guard let diagnostic = PluginManager.shared.diagnose(error: error, for: connection.type) else {
            return nil
        }
        return PluginDiagnosticItem(
            diagnostic: diagnostic,
            connectionTarget: "\(connection.host):\(connection.port)/\(connection.database)",
            username: username
        )
    }
}

struct PluginDiagnosticSheet: View {
    let item: PluginDiagnosticItem
    let onDismiss: () -> Void

    private static let issuesURL = URL(string: "https://github.com/TableProApp/TablePro/issues")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(item.diagnostic.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(item.diagnostic.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !item.diagnostic.suggestedActions.isEmpty {
                Divider()
                actionList
            }

            Divider()
            diagnosticBlock

            HStack {
                Button(String(localized: "Copy Diagnostic Info")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticText, forType: .string)
                }
                if item.diagnostic.supportURL != nil || Self.issuesURL != nil {
                    Button(String(localized: "Open Issue Tracker")) {
                        let url = item.diagnostic.supportURL ?? Self.issuesURL
                        if let url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Spacer()
                Button(String(localized: "Close"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Suggested Actions"))
                .font(.subheadline.weight(.semibold))
            ForEach(Array(item.diagnostic.suggestedActions.enumerated()), id: \.offset) { index, action in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Text(action)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    private var diagnosticBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Diagnostic Info"))
                .font(.subheadline.weight(.semibold))
            Text(diagnosticText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }

    private var diagnosticText: String {
        var lines = [
            "Target:  \(item.connectionTarget)",
            "User:    \(item.username)",
            "Error:   \(item.diagnostic.message)"
        ]
        for entry in item.diagnostic.diagnosticInfo {
            lines.append("\(entry.label): \(entry.value)")
        }
        return lines.joined(separator: "\n")
    }
}
