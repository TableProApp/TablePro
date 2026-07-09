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
    /// Anchors the window to `cursorRect`. The horizontal position is constrained to the editor's bounds when
    /// provided (so the panel never covers the right-side toolbar); the vertical position is constrained to the
    /// screen, so the panel drops below the caret and may overflow the editor into the results area rather than
    /// flipping up and covering the current line. The anchor is retained and re-applied on every later resize (see
    /// ``applyPlacement(windowSize:)``), so the panel re-derives its position as its content grows or shrinks.
    public func constrainWindowToScreenEdges(cursorRect: NSRect, font: NSFont, editorFrame: NSRect? = nil) {
        guard let window = self.window else { return }
        placementAnchor = SuggestionPlacementAnchor(cursorRect: cursorRect, font: font, editorFrame: editorFrame)
        applyPlacement(windowSize: window.frame.size)
    }

    func updateWindowSize(newSize: NSSize) {
        if let popover {
            popover.contentSize = newSize
            return
        }

        guard let window else { return }

        window.minSize = newSize
        window.maxSize = NSSize(width: CGFloat.infinity, height: newSize.height)
        window.setContentSize(newSize)

        applyPlacement(windowSize: newSize)
    }

    private func applyPlacement(windowSize: NSSize) {
        guard let anchor = placementAnchor,
              let window = self.window,
              let screenFrame = window.screen?.visibleFrame else {
            return
        }

        let placement = SuggestionWindowPlacement.compute(
            windowSize: windowSize,
            cursorRect: anchor.cursorRect,
            font: anchor.font,
            screenFrame: screenFrame,
            editorFrame: anchor.editorFrame
        )

        isWindowAboveCursor = placement.isAboveCursor
        window.setFrameOrigin(placement.origin)
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
