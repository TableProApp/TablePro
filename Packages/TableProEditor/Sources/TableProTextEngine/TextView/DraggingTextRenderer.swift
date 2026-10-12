//
//  DraggingTextRenderer.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 11/24/24.
//

import AppKit

/// Draws the visible parts of a text selection into an image for a drag.
///
/// The renderer covers the rects it's given and nothing else, so the image is the size of the part of the selection
/// the user can see. A dragging session clips its items to the visible area of the source view, so pixels outside it
/// could never be shown, and a renderer sized to the document pays for them anyway: one word selected in a document
/// that also holds a 500,000 character line built a 7,417,969 by 29 pixel bitmap, 860MB for 30 by 14 points of text.
final class DraggingTextRenderer: NSView {
    private let fillRects: [TextSelectionManager.FillRect]
    private let fragmentRenderer: LineFragmentRenderer

    override var isFlipped: Bool {
        true
    }

    /// Create a renderer for the parts of a selection that should be drawn.
    /// - Parameters:
    ///   - fillRects: The rects the selection covers, in the text view's coordinate space. Text is drawn only inside
    ///                them, so unselected text sharing a line fragment stays clear.
    ///   - fragmentRenderer: The renderer the text view draws its own line fragments with.
    /// - Returns: `nil` when no rect has an area to draw into, which is also the case when none of the selection
    ///            is on screen.
    ///
    /// Every call that can fail is made before a stored property is set. `map` is `rethrows`, and made after the
    /// assignments its error edge has to destroy both properties and partially deallocate `self` on the way out of
    /// a failable initializer. Swift 6.3.1's CopyPropagation pass crashes on that shape in a Release build ("Invalid
    /// SIL provided to OSSACompleteLifetime"), which is what stopped the v0.75.0 app build.
    init?(fillRects: [TextSelectionManager.FillRect], fragmentRenderer: LineFragmentRenderer) {
        let drawableRects = fillRects.filter { !$0.rect.isNull && !$0.rect.isEmpty }
        guard !drawableRects.isEmpty else { return nil }
        let frame = drawableRects.map(\.rect).boundingRect()

        self.fillRects = drawableRects
        self.fragmentRenderer = fragmentRenderer

        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Draws the selection into an image at another view's backing scale.
    ///
    /// The image is drawn now rather than by an `NSImage(size:flipped:drawingHandler:)` handler, which would keep the
    /// line fragments alive and draw them whenever the image is first rasterized, by which point an edit may have
    /// replaced the layout they came from.
    ///
    /// - Parameter view: The view whose window supplies the backing scale. The renderer is never in a window, so its
    ///                   own bitmap would follow the main screen rather than the screen the text view is on.
    /// - Returns: The drawn image, or `nil` when no bitmap could be made for the renderer's frame.
    func drawnImage(scaledLike view: NSView) -> NSImage? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        guard let cgImage = bitmap.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: frame.size)
    }

    /// Draws each selected piece of text, clipped to the rect the selection covers it in.
    ///
    /// Clipping is what keeps unselected text out of the image, including text that shares a line fragment with a
    /// selected word, and it's why two selections on one line both survive: each is drawn under its own clip instead
    /// of clearing everything outside itself.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for fillRect in fillRects {
            let rectInRenderer = fillRect.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            guard rectInRenderer.intersects(dirtyRect) else { continue }

            context.saveGState()
            context.clip(to: rectInRenderer)
            context.translateBy(
                x: fillRect.fragmentOrigin.x - frame.minX,
                y: fillRect.fragmentOrigin.y - frame.minY
            )
            fragmentRenderer.draw(lineFragment: fillRect.fragment, in: context, yPos: 0)
            context.restoreGState()
        }
    }
}
