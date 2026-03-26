//
//  PasteboardActionRouter.swift
//  TablePro
//
//  Routes pasteboard commands (Copy/Paste) to the correct action based on
//  the current first responder type and application state.
//

import AppKit

enum CopyAction {
    case textCopy
    case copyRows
    case copyTableNames
}

enum PasteAction {
    case textPaste
    case pasteRows
}

enum PasteboardActionRouter {
    static func resolveCopyAction(
        firstResponder: NSResponder?,
        hasRowSelection: Bool,
        hasTableSelection: Bool
    ) -> CopyAction {
        if let responder = firstResponder,
           responder is NSTextView || responder is TPTextView {
            return .textCopy
        } else if hasRowSelection {
            return .copyRows
        } else if hasTableSelection {
            return .copyTableNames
        } else {
            return .textCopy
        }
    }

    static func resolvePasteAction(
        firstResponder: NSResponder?,
        isCurrentTabEditable: Bool
    ) -> PasteAction {
        if let responder = firstResponder,
           responder is NSTextView || responder is TPTextView {
            return .textPaste
        } else if isCurrentTabEditable {
            return .pasteRows
        } else {
            return .textPaste
        }
    }
}
