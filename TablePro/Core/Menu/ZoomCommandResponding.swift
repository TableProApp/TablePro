//
//  ZoomCommandResponding.swift
//  TablePro
//

import AppKit

/// View > Zoom In and Zoom Out, named once so the menu builder needs no class. The responder chain
/// decides what zooming means: a focused diagram zooms itself, and the window falls back to the
/// editor's text size, the way Xcode gives Command-Plus to whichever pane has focus. One item per
/// verb, because two items sharing Command-= resolve by menu order rather than by focus.
@MainActor
@objc protocol ZoomCommandResponding {
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
}
