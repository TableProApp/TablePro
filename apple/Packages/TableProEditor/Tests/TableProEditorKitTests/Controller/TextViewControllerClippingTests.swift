//
//  TextViewControllerClippingTests.swift
//  TableProEditorKit
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

/// The editor draws nothing outside its own frame, whatever the host stacks above it.
///
/// The editor is the real controller configured the way the read-only code views configure it, placed under an
/// opaque band in a window and scrolled well down. The band stands for the toolbar of the EXPLAIN result pane, where
/// the line numbers of rows scrolled out of view used to paint over the Diagram, Tree and Raw picker.
@MainActor
struct TextViewControllerClippingTests {
    private static let editorFrame = NSRect(x: 0, y: 0, width: 500, height: 340)
    private static let bandHeight: CGFloat = 60

    private final class Band: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            bounds.fill()
        }
    }

    private let window: NSWindow
    private let root: NSView
    private let controller: TextViewController

    init() {
        let text = (1...300).map { "SELECT \($0) FROM orders WHERE id = \($0);" }.joined(separator: "\n")
        controller = TextViewController(
            string: text,
            language: .default,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: Mock.theme(),
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    wrapLines: false
                ),
                behavior: .init(isEditable: false),
                layout: .init(contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)),
                peripherals: .init(
                    showGutter: true,
                    showLineNumbers: true,
                    showFoldingRibbon: true,
                    showStatementRunControls: true,
                    gutterFitsContent: true
                )
            ),
            cursorPositions: [],
            highlightProviders: []
        )
        controller.loadView()

        let size = NSSize(width: Self.editorFrame.width, height: Self.editorFrame.height + Self.bandHeight)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root
        root.addSubview(Band(frame: NSRect(
            x: 0,
            y: Self.editorFrame.maxY,
            width: size.width,
            height: Self.bandHeight
        )))
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = []
        controller.view.frame = Self.editorFrame
        root.addSubview(controller.view)

        root.layoutSubtreeIfNeeded()
        controller.textView.updateFrameIfNeeded()
        controller.textView.layoutManager.layoutLines()
        controller.gutterView.updateWidthIfNeeded()
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 600))
        controller.scrollView.reflectScrolledClipView(clip)
        root.layoutSubtreeIfNeeded()
    }

    private var editorInWindow: NSRect {
        controller.view.convert(controller.view.bounds, to: nil)
    }

    /// Where `view` may draw, in window coordinates: what AppKit hands its `draw(_:)` and scopes its tracking to.
    private func visibleRectInWindow(_ view: NSView) -> NSRect {
        view.convert(view.visibleRect, to: nil)
    }

    private func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
        inner.isEmpty || outer.insetBy(dx: -0.5, dy: -0.5).contains(inner)
    }

    @Test("The gutter's line numbers paint nothing over the view above the editor")
    func gutterPaintsNothingAboveTheEditor() throws {
        controller.gutterView.needsDisplay = true
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width

        /// The band measured where the gutter cannot reach, rather than the color it fills with: the cached drawing
        /// lands in a color space that shifts the fill.
        let untouched = try #require(rep.colorAt(x: Int((root.bounds.maxX - 20) * scale), y: Int(10 * scale)))
        let gutterWidth = controller.gutterView.frame.maxX
        #expect(gutterWidth > 0)
        var inked = 0
        for x in stride(from: CGFloat(1), to: gutterWidth, by: 1) {
            for y in stride(from: CGFloat(1), to: Self.bandHeight - 1, by: 1) {
                let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))
                if !Self.isSame(color, untouched) { inked += 1 }
            }
        }
        #expect(inked == 0, "the gutter painted \(inked) points above the editor")
    }

    @Test("The gutter and its ribbons are asked to draw only inside the editor")
    func gutterDrawsOnlyInsideTheEditor() throws {
        let gutter = try #require(controller.gutterView)
        #expect(gutter.frame.height > Self.editorFrame.height, "the gutter is document-tall")
        #expect(contains(editorInWindow, visibleRectInWindow(gutter)))
        #expect(contains(editorInWindow, visibleRectInWindow(gutter.foldingRibbon)))
        #expect(contains(editorInWindow, visibleRectInWindow(gutter.statementRunRibbon)))
    }

    @Test("The find panel sliding in from above shows only inside the editor")
    func findPanelSlidesInsideTheEditor() throws {
        let find = try #require(controller.findViewController)
        find.findPanel.isHidden = false
        find.findPanelVerticalConstraint.constant = find.resolvedTopPadding - find.viewModel.panelHeight / 2
        find.view.layoutSubtreeIfNeeded()

        let panelInWindow = find.findPanel.convert(find.findPanel.bounds, to: nil)
        #expect(panelInWindow.maxY > editorInWindow.maxY, "the panel starts its slide above the editor")
        #expect(contains(editorInWindow, visibleRectInWindow(find.findPanel)))
    }

    private static func isSame(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        let tolerance: CGFloat = 0.02
        return abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
    }
}
