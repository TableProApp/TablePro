//
//  TextView+UndoRedo.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    public func setUndoManager(_ newManager: CEUndoManager) {
        self._undoManager = newManager
        self._undoManager?.setTextView(self)
    }

    override public var undoManager: UndoManager? {
        _undoManager
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
