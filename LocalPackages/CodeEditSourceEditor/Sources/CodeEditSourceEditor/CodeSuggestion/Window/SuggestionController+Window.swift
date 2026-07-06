//
//  SuggestionController+Window.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 12/22/24.
//

import AppKit
import SwiftUI

internal final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension SuggestionController {
    /// Will constrain the window's frame to be within the visible screen and, when provided, the editor's bounds.
    ///
    /// `editorFrame` is the editor pane in screen coordinates. The panel flips above the cursor when it would
    /// extend past the editor's bottom edge, so it never overlaps sibling chrome below the editor.
    public func constrainWindowToScreenEdges(cursorRect: NSRect, font: NSFont, editorFrame: NSRect? = nil) {
        guard let window = self.window,
              let screenFrame = window.screen?.visibleFrame else {
            return
        }

        let windowSize = window.frame.size
        let padding: CGFloat = 22
        var newWindowOrigin = NSPoint(
            x: cursorRect.origin.x - Self.WINDOW_PADDING
            - CodeSuggestionLabelView.HORIZONTAL_PADDING - font.pointSize,
            y: cursorRect.origin.y
        )

        // Keep the horizontal position within the screen and some padding
        let minX = screenFrame.minX + padding
        let maxX = screenFrame.maxX - windowSize.width - padding

        if newWindowOrigin.x < minX {
            newWindowOrigin.x = minX
        } else if newWindowOrigin.x > maxX {
            newWindowOrigin.x = maxX
        }

        let lowerLimit = max(screenFrame.minY, editorFrame?.minY ?? screenFrame.minY)
        let upperLimit = min(screenFrame.maxY, editorFrame?.maxY ?? screenFrame.maxY)

        // Check if the window will drop below the editor (or screen) bottom.
        // We determine whether the window drops down or upwards by choosing which
        // corner of the window we will position: `setFrameOrigin` or `setFrameTopLeftPoint`
        if newWindowOrigin.y - windowSize.height < lowerLimit {
            // If the cursor itself is below the lower limit, pin the window there with some padding
            if newWindowOrigin.y < lowerLimit {
                newWindowOrigin.y = lowerLimit + padding
            } else {
                // Place above the cursor
                newWindowOrigin.y += cursorRect.height
            }

            // Keep the top edge within the upper limit so the panel never overlaps chrome above the editor
            if newWindowOrigin.y + windowSize.height > upperLimit {
                newWindowOrigin.y = max(lowerLimit, upperLimit - windowSize.height)
            }

            isWindowAboveCursor = true
            window.setFrameOrigin(newWindowOrigin)
        } else {
            // If the window goes above the upper limit, pin it there with padding
            let maxY = upperLimit - padding
            if newWindowOrigin.y > maxY {
                newWindowOrigin.y = maxY
            }

            isWindowAboveCursor = false
            window.setFrameTopLeftPoint(newWindowOrigin)
        }
    }

    func updateWindowSize(newSize: NSSize) {
        if let popover {
            popover.contentSize = newSize
            return
        }

        guard let window else { return }
        let oldFrame = window.frame

        window.minSize = newSize
        window.maxSize = NSSize(width: CGFloat.infinity, height: newSize.height)

        window.setContentSize(newSize)

        if isWindowAboveCursor && oldFrame.size.height != newSize.height {
            window.setFrameOrigin(oldFrame.origin)
        }
    }

    func updateWindowSizeFromContent() {
        guard let hostingView = window?.contentView as? NSHostingView<SuggestionContentView> else { return }
        let fitting = hostingView.fittingSize
        let minWidth: CGFloat = 256
        let newSize = NSSize(width: max(fitting.width, minWidth), height: fitting.height)
        updateWindowSize(newSize: newSize)
    }

    // MARK: - Private Methods

    static func makeWindow() -> NSPanel {
        let panel = SuggestionPanel(
            contentRect: .zero,
            styleMask: [.resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.tabbingMode = .disallowed
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear

        return panel
    }
}
