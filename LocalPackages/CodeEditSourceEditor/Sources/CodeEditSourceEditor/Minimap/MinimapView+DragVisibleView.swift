//
//  MinimapView+DragVisibleView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/16/25.
//

import AppKit

extension MinimapView {
    /// Responds to a drag gesture on the document visible view. Dragging the view scrolls the editor a relative amount.
    @objc func documentVisibleViewDragged(_ sender: NSPanGestureRecognizer) {
        guard let editorScrollView = textView?.enclosingScrollView else {
            return
        }

        // Convert the drag distance in the minimap to the drag distance in the editor.
        let translation = sender.translation(in: documentVisibleView)
        let ratio = if minimapHeight > containerHeight {
            containerHeight / (textView?.frame.height ?? 0.0)
        } else {
            editorToMinimapHeightRatio
        }
        let editorTranslation = translation.y / ratio
        sender.setTranslation(.zero, in: documentVisibleView)

        // Clamp the scroll amount to the content, so we don't scroll crazy far past the end of the document.
        var newScrollViewY = editorScrollView.contentView.bounds.origin.y - editorTranslation
        // Minimum Y value is the top of the scroll view
        newScrollViewY = max(-editorScrollView.contentInsets.top, newScrollViewY)
        newScrollViewY = min( // Max y value needs to take into account the editor overscroll
            editorScrollView.documentMaxOriginY - editorScrollView.contentInsets.top, // Relative to the content's top
            newScrollViewY
        )

        editorScrollView.contentView.scroll(
            to: NSPoint(
                x: editorScrollView.contentView.bounds.origin.x,
                y: newScrollViewY
            )
        )
        editorScrollView.reflectScrolledClipView(editorScrollView.contentView)
    }
}
