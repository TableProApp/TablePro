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
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Copy error message"))
            if let onDismiss {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
}

#Preview {
    InlineErrorBanner(
        message: "ERROR 1064 (42000): You have an error in your SQL syntax",
        onDismiss: {}
    )
    .frame(width: 600)
}
