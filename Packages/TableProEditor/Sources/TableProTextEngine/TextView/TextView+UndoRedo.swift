//
//  TextView+UndoRedo.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    public func setUndoManager(_ newManager: CEUndoManager) {
        self.editorUndoManager = newManager
        self.editorUndoManager?.setTextView(self)
    }

    override public var undoManager: UndoManager? {
        editorUndoManager
    }

    @objc func undo(_ sender: AnyObject?) {
        if allowsUndo {
            undoManager?.undo()
        }
    }

    @objc func redo(_ sender: AnyObject?) {
        if allowsUndo {
            undoManager?.redo()
        }
    }
}
