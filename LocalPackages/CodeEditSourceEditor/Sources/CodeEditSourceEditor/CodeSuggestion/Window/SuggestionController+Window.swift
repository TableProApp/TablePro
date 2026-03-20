//
//  SuggestionController+Window.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 12/22/24.
//

import AppKit
import SwiftUI

final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

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
