//
//  SystemColorResolutionTests.swift
//  TableProTextEngine
//

import AppKit
@testable import TableProTextEngine
import Testing

/// A layer keeps the color it is handed. Every system color the text view puts in one is resolved for the text
/// view's own appearance and resolved again when that appearance changes.
@MainActor
struct SystemColorResolutionTests {
    @Test("An underline is resolved for the text view's appearance and again after it changes")
    func underlineFollowsTheTextViewAppearance() throws {
        let textView = makeLaidOutTextView()
        textView.appearance = NSAppearance(named: .darkAqua)
        let manager = try #require(textView.emphasisManager)
        manager.addEmphasis(Emphasis(range: NSRange(location: 0, length: 5), style: .underline(color: .textColor)), for: "e")
        let layer = try #require(shapeLayer(in: textView))
        #expect(try brightness(of: layer.strokeColor) > 0.9)

        textView.appearance = NSAppearance(named: .aqua)
        textView.viewDidChangeEffectiveAppearance()

        #expect(try brightness(of: layer.strokeColor) < 0.1)
    }

    @Test("Other find matches use the unemphasized selection colors")
    func inactiveMatchUsesTheUnemphasizedSelection() throws {
        let textView = makeLaidOutTextView()
        let appearance = try #require(NSAppearance(named: .darkAqua))
        textView.appearance = appearance
        let manager = try #require(textView.emphasisManager)
        manager.addEmphasis(Emphasis(range: NSRange(location: 0, length: 5), inactive: true), for: "e")
        let layer = try #require(shapeLayer(in: textView))

        let expected = NSColor.unemphasizedSelectedTextBackgroundColor.safeCGColor(in: appearance)
        #expect(layer.fillColor == expected)
    }

    @Test("A drawn caret resolves its color where AppKit draws it")
    func cursorViewResolvesInItsAppearance() throws {
        let cursor = CursorView(color: .textColor)
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))

        dark.performAsCurrentDrawingAppearance { cursor.updateLayer() }
        #expect(try brightness(of: cursor.layer?.backgroundColor) > 0.9)

        light.performAsCurrentDrawingAppearance { cursor.updateLayer() }
        #expect(try brightness(of: cursor.layer?.backgroundColor) < 0.1)
    }

    @Test("With no caret color set, the caret is the system's")
    func caretDefaultsToTheSystemColor() {
        let textView = makeLaidOutTextView()
        let manager = textView.selectionManager

        #expect(manager?.insertionPointColor == nil)
        #expect(manager?.drawnInsertionPointColor == TextSelectionManager.nativeInsertionPointColor)
        if #available(macOS 14.0, *) {
            #expect(TextSelectionManager.nativeInsertionPointColor == .textInsertionPointColor)
        }
    }

    private func makeLaidOutTextView() -> TextView {
        let textView = TextView(string: "Lorem Ipsum")
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        return textView
    }

    private func shapeLayer(in textView: TextView) -> CAShapeLayer? {
        textView.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first
    }

    private func brightness(of color: CGColor?) throws -> CGFloat {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let components = try #require(color?.converted(to: space, intent: .defaultIntent, options: nil)?.components)
        return components.prefix(3).reduce(0, +) / 3
    }
}
