//
//  TextView+SetText.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 1/12/25.
//

import AppKit

public extension TextView {
    /// Sets the text view's text to a new value.
    /// - Parameter text: The new contents of the text view.
    func setText(_ text: String) {
        let newStorage = NSTextStorage(string: text)
        self.setTextStorage(newStorage)
    }

    /// Set a new text storage object for the view.
    /// - Parameter textStorage: The new text storage to use.
    func setTextStorage(_ textStorage: NSTextStorage) {
        setTextStorage(textStorage, adopting: nil)
    }

    /// Set a text storage object the view showed before, with the lines it was laid out in then.
    ///
    /// The storage already carries the typing attributes and its styles, and `lines` were detached from this same
    /// storage, so the text is not split into lines again.
    /// - Parameters:
    ///   - textStorage: The text storage to show.
    ///   - lines: The lines detached from `textStorage`, or `nil` to build them.
    func setTextStorage(_ textStorage: NSTextStorage, adopting lines: TextLayoutManager.DetachedLines?) {
        self.textStorage = textStorage

        if let storageDelegate = textStorage.delegate as? MultiStorageDelegate {
            self.storageDelegate = storageDelegate
        }

        subviews.forEach { view in
            view.removeFromSuperview()
        }

        if lines == nil {
            textStorage.addAttributes(typingAttributes, range: documentRange)
        }
        layoutManager.attachments.removeAll()
        layoutManager.textStorage = textStorage
        if let lines {
            layoutManager.reset(adopting: lines)
        } else {
            layoutManager.reset()
        }
        storageDelegate.addDelegate(layoutManager)

        selectionManager.textStorage = textStorage
        selectionManager.setSelectedRanges(selectionManager.textSelections.map { $0.range })
        NotificationCenter.default.post(
            Notification(
                name: TextSelectionManager.selectionChangedNotification,
                object: selectionManager
            )
        )

        editorUndoManager?.clearStack()

        textStorage.delegate = storageDelegate
        needsDisplay = true
        needsLayout = true
    }
}
