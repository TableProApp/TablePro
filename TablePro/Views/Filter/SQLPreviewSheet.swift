//
//  SQLPreviewSheet.swift
//  TablePro
//
//  Modal sheet to display generated SQL from filters.
//  Extracted from FilterPanelView for better maintainability.
//

import SwiftUI

/// Modal sheet to display generated SQL
struct SQLPreviewSheet: View {
    let sql: String
    let tableName: String
    let databaseType: DatabaseType
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Generated WHERE Clause")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.default))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Close"))
                .help(String(localized: "Close preview"))
            }

            ScrollView {
                Text(sql.isEmpty ? "(no conditions)" : sql)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            HStack {
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        Text(copied ? "Copied!" : "Copy")
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sql.isEmpty)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(minWidth: 400, idealWidth: 480, maxWidth: 600, minHeight: 250, idealHeight: 300, maxHeight: 450)
        .onExitCommand {
            dismiss()
        }
    }

    private func copyToClipboard() {
        ClipboardService.shared.writeText(sql)
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied to clipboard")).post()

        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
