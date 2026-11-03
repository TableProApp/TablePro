//
//  InlineErrorBanner.swift
//  TablePro
//

import AppKit
import SwiftUI

struct InlineErrorBanner: View {
    let message: String
    var onFixWithAI: (() -> Void)?
    var onDismiss: (() -> Void)?
    // A sheet footer shows it without the pane bar material.
    var onBar = true

    private let maxMessageHeight: CGFloat = 96
    private let minMessageHeight: CGFloat = 16
    @State private var messageHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private var messageFits: Bool { messageHeight <= shownHeight + 0.5 }

    var body: some View {
        PaneNoticeBar(
            severity: .error,
            alignment: .top,
            onBar: onBar,
            dismissLabel: String(localized: "Dismiss error"),
            onDismiss: onDismiss
        ) {
            ScrollView(.vertical) {
                RevealedTextView(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("query-error-message")
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        messageHeight = height
                    }
            }
            // Gives way down to one line in a short pane, so the bars above and below it stay inside the pane.
            .frame(
                minHeight: min(messageHeight, minMessageHeight),
                maxHeight: min(messageHeight, maxMessageHeight)
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                shownHeight = height
            }
            .scrollDisabled(messageFits)
            .scrollBounceBasedOnSize()
        } actions: {
            if let onFixWithAI {
                Button(String(localized: "Fix with AI"), action: onFixWithAI)
            }
            PaneNoticeCopyButton(text: message, label: String(localized: "Copy error message"))
        }
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
