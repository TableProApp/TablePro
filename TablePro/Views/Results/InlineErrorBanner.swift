//
//  InlineErrorBanner.swift
//  TablePro
//
//  Dismissable red error banner for query errors, displayed inline above results.
//

import SwiftUI

struct InlineErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?
    var onAIFix: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            if let onAIFix {
                Button("Fix with AI") { onAIFix() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
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
    VStack {
        InlineErrorBanner(
            message: "ERROR 1064 (42000): You have an error in your SQL syntax",
            onDismiss: {},
            onAIFix: {}
        )
        InlineErrorBanner(
            message: "Connection refused",
            onDismiss: {}
        )
    }
    .frame(width: 600)
}
