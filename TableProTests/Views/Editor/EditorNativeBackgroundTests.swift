//
//  EditorNativeBackgroundTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProEditorKit
import TableProGrammars
import TableProTextEngine
import Testing

@MainActor
struct EditorNativeBackgroundTests {
    private func render(appearance name: NSAppearance.Name) throws -> NSBitmapImageRep {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        let themeAppearance: ThemeAppearance = name == .darkAqua ? .dark : .light
        engine.adopt(ThemeSelection(pair: .builtIn, effectiveAppearance: themeAppearance))

        let controller = TextViewController(
            string: "SELECT 1;",
            language: .sql,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: engine.makeEditorTheme(),
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    lineHeightMultiple: 1.0,
                    wrapLines: false,
                    tabWidth: 4
                )
            ),
            cursorPositions: [],
            highlightProviders: [],
            coordinators: []
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: name)
        controller.loadView()
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()

        let view = controller.view
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func color(_ rep: NSBitmapImageRep, x: Int, fromTop y: Int) throws -> NSColor {
        let scale = rep.pixelsWide / 600
        return try #require(rep.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB))
    }

    private func hex(_ color: NSColor) -> String {
        String(
            format: "#%02X%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255)),
            Int(round(color.alphaComponent * 255))
        )
    }

    @Test("Under the default theme the text area below the text is the same text background as the gutter",
          arguments: [NSAppearance.Name.aqua, .darkAqua])
    func textAreaMatchesGutter(appearance: NSAppearance.Name) throws {
        let rep = try render(appearance: appearance)
        let gutter = hex(try color(rep, x: 8, fromTop: 300))
        let textArea = hex(try color(rep, x: 400, fromTop: 300))
        #expect(textArea == gutter, "text area \(textArea), gutter \(gutter)")
    }
}
