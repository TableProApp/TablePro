//
//  EditorThemeBridgeTests.swift
//  TableProTests
//
//  The colours the app's theme engine hands the editor. Everything about how the editor then paints
//  them lives with the editor, in TableProEditorKitTests.
//

import AppKit
@testable import TablePro
import TableProEditorKit
import Testing

struct EditorThemeBridgeTests {
    @MainActor
    @Test("The theme's operator and function colours reach the editor")
    func themeCarriesOperatorAndFunctionColors() {
        let colors = ThemeEngine.shared.colors.editor
        let theme = ThemeEngine.shared.makeEditorTheme()

        #expect(Self.sameColor(theme.operators.color, colors.operator))
        #expect(Self.sameColor(theme.functions.color, colors.function))
    }

    private static func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.sRGB), let right = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(left.redComponent - right.redComponent) < 0.001
            && abs(left.greenComponent - right.greenComponent) < 0.001
            && abs(left.blueComponent - right.blueComponent) < 0.001
    }
}
