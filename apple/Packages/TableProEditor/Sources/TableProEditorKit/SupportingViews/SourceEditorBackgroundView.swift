//
//  SourceEditorBackgroundView.swift
//  TableProEditorKit
//

import AppKit

/// The editor's background, behind everything else it draws and across its whole frame.
///
/// The text view and the gutter each paint their own frame, which leaves the content insets between them and the
/// editor's edge. Painted by the scroll view instead, as `NSScrollView.backgroundColor`, a semantic color such as
/// `textBackgroundColor` comes out as the window's background inside a window with a toolbar, so in Dark those
/// margins read lighter than the text beside them. Drawn here the way the text view draws its own, the color holds.
final class SourceEditorBackgroundView: NSView {
    var fillColor: NSColor? {
        didSet {
            guard fillColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Bounded by hand: from macOS 14 a view that does not clip is handed dirty rects that reach past its bounds, and
    /// filling one painted the host's toolbar above the editor.
    override func draw(_ dirtyRect: NSRect) {
        guard let fillColor else { return }
        fillColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
