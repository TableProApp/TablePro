//
//  TextView+SetText.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 1/12/25.
//

import AppKit

extension TextView {
    /// Sets the text view's text to a new value.
    /// - Parameter text: The new contents of the text view.
    public func setText(_ text: String) {
        let newStorage = NSTextStorage(string: text)
        self.setTextStorage(newStorage)
    }

    /// Set a new text storage object for the view.
    /// - Parameter textStorage: The new text storage to use.
    public func setTextStorage(_ textStorage: NSTextStorage) {
        self.textStorage = textStorage

        if let storageDelegate = textStorage.delegate as? MultiStorageDelegate {
            self.storageDelegate = storageDelegate
        }

        subviews.forEach { view in
            view.removeFromSuperview()
        }

        textStorage.addAttributes(typingAttributes, range: documentRange)
        layoutManager.textStorage = textStorage
        layoutManager.reset()
        storageDelegate.addDelegate(layoutManager)

        selectionManager.textStorage = textStorage
        selectionManager.setSelectedRanges(selectionManager.textSelections.map { $0.range })
        NotificationCenter.default.post(
            Notification(
                name: TextSelectionManager.selectionChangedNotification,
                object: selectionManager
            )
        )

        _undoManager?.clearStack()

        textStorage.delegate = storageDelegate
        needsDisplay = true
        needsLayout = true
    }
}
