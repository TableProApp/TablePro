//
//  ServerOutputTextView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// A read-only text view that holds thousands of lines of server output without laying them out as SwiftUI text.
/// The Message tab's run log uses it for the same reason.
struct ServerOutputTextView: NSViewRepresentable {
    let text: String
    var accessibilityLabel = String(localized: "Server output")
    var accessibilityIdentifier = "server-output-text"

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        context.coordinator.themeStyle = ThemeTextViewStyle(
            textView: textView,
            natives: ThemeTextViewStyle.Natives(of: textView)
        )
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var themeStyle: ThemeTextViewStyle?
    }
}
