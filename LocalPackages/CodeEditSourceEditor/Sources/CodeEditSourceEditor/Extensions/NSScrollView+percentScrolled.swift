//
//  NSScrollView+percentScrolled.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/15/25.
//

import AppKit

extension NSScrollView {
    /// The maximum `Y` value that can be scrolled to, as the origin of the `documentVisibleRect`.
    var documentMaxOriginY: CGFloat {
        let totalHeight = (documentView?.frame.height ?? 0.0) + contentInsets.vertical
        return totalHeight - documentVisibleRect.height
    }

    /// The percent amount the scroll view has been scrolled. Measured as the available space that can be scrolled.
    var percentScrolled: CGFloat {
        let currentYPos = documentVisibleRect.origin.y + contentInsets.top
        return currentYPos / documentMaxOriginY
    }
}
