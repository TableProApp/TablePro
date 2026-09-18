//
//  TextValueEditor.swift
//  TablePro
//

import AppKit
import SwiftUI

/// A scrolling plain-text view for a stored value.
///
/// `TextField` is an `NSTextField` at every `axis` setting, so it clips instead of scrolling, and
/// `TextEditor` leaves AppKit's quote, dash and text substitutions on with no API to reach them,
/// which would rewrite a value on its way to the database.
internal struct TextValueEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var font: NSFont
    var borderType: NSBorderType = .noBorder
    var movesFocusOnTab: Bool = false
    var textContainerInset = NSSize(width: 4, height: 6)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        TextValueEditor.applyPlainTextDefaults(to: textView)
        textView.delegate = context.coordinator
        applyConfiguration(to: scrollView, textView: textView, coordinator: context.coordinator)

        textView.string = text
        context.coordinator.lastAppliedText = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        applyConfiguration(to: scrollView, textView: textView, coordinator: context.coordinator)

        guard context.coordinator.lastAppliedText != text else { return }
        context.coordinator.lastAppliedText = text

        let caret = textView.selectedRange().location
        textView.string = text
        let clamped = min(caret, (text as NSString).length)
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, movesFocusOnTab: movesFocusOnTab)
    }

    /// AppKit substitutes typed quotes, dashes and text by default. A stored value has to reach
    /// the database as the user typed it, so every substitution is off.
    static func applyPlainTextDefaults(to textView: NSTextView) {
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
    }

    private func applyConfiguration(to scrollView: NSScrollView, textView: NSTextView, coordinator: Coordinator) {
        coordinator.text = $text
        coordinator.movesFocusOnTab = movesFocusOnTab
        if scrollView.borderType != borderType {
            scrollView.borderType = borderType
        }
        if textView.font != font {
            textView.font = font
        }
        if textView.textContainerInset != textContainerInset {
            textView.textContainerInset = textContainerInset
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if !textView.isSelectable {
            textView.isSelectable = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var movesFocusOnTab: Bool
        /// What the text view was last given. Comparing against it answers "has the binding
        /// moved" without bridging the whole NSString back, which costs 45ms on a 1 MB value and
        /// would run on every SwiftUI update pass.
        var lastAppliedText: String = ""

        init(text: Binding<String>, movesFocusOnTab: Bool) {
            self.text = text
            self.movesFocusOnTab = movesFocusOnTab
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            lastAppliedText = value
            text.wrappedValue = value
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard movesFocusOnTab else { return false }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(nil)
                return true
            }
            return false
        }
    }
}
