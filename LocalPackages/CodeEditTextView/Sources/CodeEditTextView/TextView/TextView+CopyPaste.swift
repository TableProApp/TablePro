//
//  TextView+CopyPaste.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    @objc open func copy(_ sender: AnyObject) {
        guard let textSelections = selectionManager?
            .textSelections
            .compactMap({ textStorage.attributedSubstring(from: $0.range) }),
              !textSelections.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textSelections)
    }

    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc open func cut(_ sender: AnyObject) {
        copy(sender)
        deleteBackward(sender)
    }

    @objc open func delete(_ sender: AnyObject) {
        deleteBackward(sender)
    }
}
