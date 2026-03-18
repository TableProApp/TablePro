//
//  SourceEditorConfiguration+Layout.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/16/25.
//

import AppKit

extension SourceEditorConfiguration {
    public struct Layout: Equatable {
        /// The distance to overscroll the editor by, as a multiple of the visible editor height.
        public var editorOverscroll: CGFloat = 0

        /// Insets to use to offset the content in the enclosing scroll view. Leave as `nil` to let the scroll view
        /// automatically adjust content insets.
        public var contentInsets: NSEdgeInsets?

        /// An additional amount to inset the text of the editor by.
        public var additionalTextInsets: NSEdgeInsets?

        public init(
            editorOverscroll: CGFloat = 0,
            contentInsets: NSEdgeInsets? = nil,
            additionalTextInsets: NSEdgeInsets? = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        ) {
            self.editorOverscroll = editorOverscroll
            self.contentInsets = contentInsets
            self.additionalTextInsets = additionalTextInsets
        }

        @MainActor
        func didSetOnController(controller: TextViewController, oldConfig: Layout?) {
            if oldConfig?.editorOverscroll != editorOverscroll {
                controller.textView.overscrollAmount = editorOverscroll
            }

            if oldConfig?.contentInsets != contentInsets {
                controller.updateContentInsets()
            }

            if oldConfig?.additionalTextInsets != additionalTextInsets {
                controller.styleScrollView()
            }
        }
    }
}
