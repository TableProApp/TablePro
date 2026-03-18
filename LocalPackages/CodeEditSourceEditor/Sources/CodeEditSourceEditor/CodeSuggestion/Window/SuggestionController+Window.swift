//
//  SuggestionController+Window.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 12/22/24.
//

import AppKit

extension SuggestionController {
    /// Will constrain the window's frame to be within the visible screen
    public func constrainWindowToScreenEdges(cursorRect: NSRect, font: NSFont) {
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

        // Check if the window will go below the screen
        // We determine whether the window drops down or upwards by choosing which
        // corner of the window we will position: `setFrameOrigin` or `setFrameTopLeftPoint`
        if newWindowOrigin.y - windowSize.height < screenFrame.minY {
            // If the cursor itself is below the screen, then position the window
            // at the bottom of the screen with some padding
            if newWindowOrigin.y < screenFrame.minY {
                newWindowOrigin.y = screenFrame.minY + padding
            } else {
                // Place above the cursor
                newWindowOrigin.y += cursorRect.height
            }

            isWindowAboveCursor = true
            window.setFrameOrigin(newWindowOrigin)
        } else {
            // If the window goes above the screen, position it below the screen with padding
            let maxY = screenFrame.maxY - padding
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

    // MARK: - Private Methods

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.hasShadow = true
        window.isOpaque = false
        window.tabbingMode = .disallowed
        window.hidesOnDeactivate = true
        window.backgroundColor = .clear

        return window
    }
}
