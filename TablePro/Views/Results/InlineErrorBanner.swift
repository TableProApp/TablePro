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

    private let maxMessageHeight: CGFloat = 96
    @State private var messageHeight: CGFloat = 0

    private var messageFits: Bool { messageHeight <= maxMessageHeight }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            ScrollView(.vertical) {
                Text(message)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        messageHeight = height
                    }
            }
            .frame(height: min(messageHeight, maxMessageHeight))
            .scrollDisabled(messageFits)
            .scrollBounceBehavior(.basedOnSize)
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
    VStack(spacing: 0) {
        InlineErrorBanner(message: "near \"Album\": syntax error", onDismiss: {})
        Divider()
        InlineErrorBanner(
            message: String(
                repeating: "ERROR 1064 (42000): You have an error in your SQL syntax near this token. ",
                count: 8
            ),
            onFixWithAI: {},
            onDismiss: {}
        )
    }
    .frame(width: 600)
}
