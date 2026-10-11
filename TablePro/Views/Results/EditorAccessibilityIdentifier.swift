//
//  EditorAccessibilityIdentifier.swift
//  TablePro
//

import AppKit
import TableProEditorKit

/// Names the editor's `NSTextView` for accessibility, and for the UI tests that reach it that way.
///
/// `.accessibilityIdentifier(...)` on the SwiftUI side names the representable, not the text view
/// underneath it, so a query for that identifier matches nothing. `UITestCase.editorTextView` says
/// so in as many words and keeps a `firstMatch` fallback because of it, which is only unambiguous
/// while exactly one text view is on screen. The row inspector has several.
///
/// A coordinator is the documented way in: `prepareCoordinator` runs from `TextViewController`
/// with the text view already built, which is what an identifier has to be set on.
internal final class EditorAccessibilityIdentifier: TextViewCoordinator {
    private let identifier: String

    internal init(_ identifier: String) {
        self.identifier = identifier
    }

    internal func prepareCoordinator(controller: TextViewController) {
        controller.textView?.setAccessibilityIdentifier(identifier)
    }

    internal func destroy() {}
}
