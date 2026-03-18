//
//  MinimapContentView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/16/25.
//

import AppKit
import CodeEditTextView

/// Displays the real contents of the minimap. The layout manager and selection manager place views and draw into this
/// view.
///
/// Height and position are managed by ``MinimapView``.
public class MinimapContentView: FlippedNSView {
    weak var textView: TextView?
    weak var layoutManager: TextLayoutManager?
    weak var selectionManager: TextSelectionManager?

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if textView?.isSelectable ?? false {
            selectionManager?.drawSelections(in: dirtyRect)
        }
    }

    override public func layout() {
        super.layout()
        layoutManager?.layoutLines()
    }
}
