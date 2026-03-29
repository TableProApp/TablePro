//
//  TextView+ReplaceCharacters.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit
import TextStory

extension TextView {
    /// Replace the characters in the given ranges with the given string.
    /// - Parameters:
    ///   - ranges: The ranges to replace
    ///   - string: The string to insert in the ranges.
    ///   - skipUpdateSelection: Skips the selection update step
    public func replaceCharacters(
        in ranges: [NSRange],
        with string: String,
        skipUpdateSelection: Bool = false
    ) {
        guard isEditable else { return }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)
        textStorage.beginEditing()

        func valid(range: NSRange, string: String) -> Bool {
            (!range.isEmpty || !string.isEmpty) &&
            (delegate?.textView(self, shouldReplaceContentsIn: range, with: string) ?? true)
        }

        // Can't insert an empty string into an empty range. One must be not empty
        for range in ranges.sorted(by: { $0.location > $1.location }) where valid(range: range, string: string) {
            delegate?.textView(self, willReplaceContentsIn: range, with: string)

            _undoManager?.registerMutation(
                TextMutation(string: string as String, range: range, limit: textStorage.length)
            )
            textStorage.replaceCharacters(
                in: range,
                with: NSAttributedString(string: string, attributes: typingAttributes)
            )
            if !skipUpdateSelection {
                selectionManager.didReplaceCharacters(in: range, replacementLength: (string as NSString).length)
            }

            delegate?.textView(self, didReplaceContentsIn: range, with: string)
        }

        textStorage.endEditing()

        if !skipUpdateSelection {
            selectionManager.notifyAfterEdit()
        }
        NotificationCenter.default.post(name: Self.textDidChangeNotification, object: self)

        // `scrollSelectionToVisible` is a little expensive to call every time. Instead we just check if the first
        // selection is entirely visible. `.contains` checks that all points in the rect are inside. 
        if let selection = selectionManager.textSelections.first, !visibleRect.contains(selection.boundingRect) {
            scrollSelectionToVisible()
        }
    }

    /// Replace the characters in a range with a new string.
    /// - Parameters:
    ///   - range: The range to replace.
    ///   - string: The string to insert in the range.
    ///   - skipUpdateSelection: Skips the selection update step
    public func replaceCharacters(
        in range: NSRange,
        with string: String,
        skipUpdateSelection: Bool = false
    ) {
        replaceCharacters(in: [range], with: string, skipUpdateSelection: skipUpdateSelection)
    }

    /// Iterates over all text selections in the `TextView` and applies the provided callback.
    ///
    /// This method is typically used when you need to perform an operation on each text selection in the editor,
    /// such as adjusting indentation, or other selection-based operations. The callback
    /// is executed for each selection, and you can modify the selection or perform related tasks.
    ///
    /// - Parameters:
    /// - callback: A closure that will be executed for each selection in the `TextView`. It takes two parameters:
    /// a `TextView` instance, allowing access to the view's properties and methods and a
    /// `TextSelectionManager.TextSelection` representing the current selection to operate on.
    ///
    /// - Note: The selections are iterated in reverse order, so modifications to earlier selections won't affect later
    ///   ones. The method automatically calls `notifyAfterEdit()` on the `selectionManager` after all
    ///   selections are processed.
    public func editSelections(callback: (TextView, TextSelectionManager.TextSelection) -> Void) {
        for textSelection in selectionManager.textSelections.reversed() {
            callback(self, textSelection)
        }
        selectionManager.notifyAfterEdit(force: true)
    }
}
