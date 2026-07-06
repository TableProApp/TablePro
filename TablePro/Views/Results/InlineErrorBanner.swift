//
//  InlineErrorBanner.swift
//  TablePro
//
//  Dismissable red error banner for query errors, displayed inline above results.
//

import AppKit
import SwiftUI

struct InlineErrorBanner: View {
    let message: String
    var onFixWithAI: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            ScrollView(.vertical) {
                Text(message)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            if let onFixWithAI {
                Button(String(localized: "Fix with AI")) { onFixWithAI() }
                    .controlSize(.small)
            }
            Button {
                ClipboardService.shared.writeText(message)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Copy error message"))
            .accessibilityLabel(String(localized: "Copy error message"))
            if let onDismiss {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Dismiss error"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.08))
    }
}

#Preview {
    InlineErrorBanner(
        message: "ERROR 1064 (42000): You have an error in your SQL syntax",
        onDismiss: {}
    )
    .frame(width: 600)
}
