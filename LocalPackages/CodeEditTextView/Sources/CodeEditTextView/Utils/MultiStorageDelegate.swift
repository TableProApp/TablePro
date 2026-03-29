//
//  MultiStorageDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/25/23.
//

import AppKit

public class MultiStorageDelegate: NSObject, NSTextStorageDelegate {
    private var delegates = NSHashTable<NSTextStorageDelegate>.weakObjects()

    public func addDelegate(_ delegate: NSTextStorageDelegate) {
        delegates.add(delegate)
    }

    public func removeDelegate(_ delegate: NSTextStorageDelegate) {
        delegates.remove(delegate)
    }

    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        delegates.allObjects.forEach { delegate in
            delegate.textStorage?(textStorage, didProcessEditing: editedMask, range: editedRange, changeInLength: delta)
        }
    }

    public func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        delegates.allObjects.forEach { delegate in
            delegate
                .textStorage?(textStorage, willProcessEditing: editedMask, range: editedRange, changeInLength: delta)
        }
    }
}
