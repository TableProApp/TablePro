//
//  SuggestionController+Window.swift
//  TableProTextEngine
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

    // The caret's screen, since a panel not yet ordered front may still report the one its last session was on.
    private func applyPlacement(windowSize: NSSize) {
        guard let anchor = placementAnchor,
              let window = self.window,
              let screenFrame = (Self.screen(holding: anchor.cursorRect) ?? window.screen)?.visibleFrame else {
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

    // A caret rect can be zero wide, which no frame intersects, so its center decides.
    private static func screen(holding cursorRect: NSRect) -> NSScreen? {
        let center = NSPoint(x: cursorRect.midX, y: cursorRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    func updateWindowSizeFromContent() {
        guard let window, let hostingView = window.contentView as? NSHostingView<SuggestionContentView> else { return }
        let newSize = contentSize(fallback: hostingView)
        if popover == nil, window.contentRect(forFrameRect: window.frame).size == newSize { return }
        updateWindowSize(newSize: newSize)
    }

    // The list's size follows from the items alone; laying out the whole panel for it cost a SwiftUI pass per key.
    func contentSize(fallback hostingView: NSHostingView<SuggestionContentView>) -> NSSize {
        let minWidth: CGFloat = 256
        let items = model.items
        guard !items.isEmpty else {
            let fitting = hostingView.fittingSize
            return NSSize(width: max(fitting.width, minWidth), height: fitting.height)
        }
        let font = model.activeTextView?.font ?? NSFont.systemFont(ofSize: 12)
        let width = SuggestionContentView.contentWidth(for: items, font: font)
        var height = SuggestionContentView.listHeight(for: items)
        if let item = model.selectedItem, SuggestionContentView.hasPreview(item) {
            height += previewHeight(for: item, width: width, font: font)
        }
        return NSSize(width: max(width, minWidth), height: height)
    }

    private func previewHeight(for item: CodeSuggestionEntry, width: CGFloat, font: NSFont) -> CGFloat {
        let key = SuggestionPreviewSizeKey(item: item, width: width, font: font)
        if let cached = previewHeights[key] { return cached }
        let highlight = model.syntaxHighlights(forIndex: model.selectedIndex)
        previewSizer.rootView = AnyView(
            VStack(spacing: 0) {
                Divider()
                SuggestionPreviewView(item: item, syntaxHighlight: highlight, font: font)
            }
            .frame(width: width)
        )
        let height = previewSizer.fittingSize.height
        if previewHeights.count >= 64 { previewHeights.removeAll() }
        previewHeights[key] = height
        return height
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

// What the preview's height depends on: its text, the font and the width it wraps in.
struct SuggestionPreviewSizeKey: Hashable {
    let documentation: String?
    let sourcePreview: String?
    let pathComponents: [String]?
    let width: CGFloat
    let fontName: String
    let fontSize: CGFloat

    init(item: CodeSuggestionEntry, width: CGFloat, font: NSFont) {
        documentation = item.documentation
        sourcePreview = item.sourcePreview
        pathComponents = item.pathComponents
        self.width = width
        fontName = font.fontName
        fontSize = font.pointSize
    }
}
