//
//  NSView+Focus.swift
//  TablePro
//

import AppKit

extension NSView {
    func firstEditableTextField() -> NSTextField? {
        if let textField = self as? NSTextField, textField.isEditable {
            return textField
        }
        for subview in subviews {
            if let found = subview.firstEditableTextField() {
                return found
            }
        }
        return nil
    }
}
