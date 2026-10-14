//
//  ValueFontTests.swift
//  TableProTests
//
//  The row inspector, the cell popovers and the Compare row diff all render a stored value, so they
//  follow the data grid font rather than the editor font, as the grid's own inline cell editor
//  already did. Both settings ship at the same family and size, so a regression is invisible until
//  a user splits them.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// Both tests change the fonts on the shared `ThemeEngine`. What keeps that from reaching a
/// suite running in parallel is that both bodies are synchronous and `@MainActor`, so nothing else on
/// the main actor can interleave between applying the test fonts and restoring the original ones, the
/// same way `DataGridRowTintThemeTests` holds. Adding an `await` inside `withTypography` breaks it.
@Suite("Stored value font", .serialized)
@MainActor
struct ValueFontTests {
    private static func typography(editorSize: Int, gridSize: Int) -> TypographySettings {
        TypographySettings(
            editorFontFamily: "Menlo",
            editorFontSize: editorSize,
            dataGridFontFamily: "Courier",
            dataGridFontSize: gridSize
        )
    }

    private func withTypography(_ typography: TypographySettings, _ body: () -> Void) {
        let previous = AppSettingsManager.shared.typography
        ThemeEngine.shared.apply(typography: typography)
        body()
        ThemeEngine.shared.apply(typography: previous)
    }

    // MARK: - Which setting the value font comes from

    @Test("The value font is the data grid font, not the editor font")
    func valueFontFollowsTheDataGridFont() {
        withTypography(Self.typography(editorSize: 18, gridSize: 11)) {
            let engine = ThemeEngine.shared
            #expect(engine.valueFont == engine.dataGridFonts.regular)
            #expect(engine.valueFont != engine.editorFonts.font)
        }
    }

    /// The contested half of #2393, stated as behaviour rather than as an implementation equality: the
    /// issue asked for the editor font and this ships the data grid font instead, so moving the editor
    /// setting must leave every value control where it was.
    @Test("Changing only the editor size leaves the value font alone")
    func valueFontIgnoresTheEditorSize() {
        var afterSmall: NSFont?
        var afterLarge: NSFont?
        withTypography(Self.typography(editorSize: 11, gridSize: 13)) { afterSmall = ThemeEngine.shared.valueFont }
        withTypography(Self.typography(editorSize: 18, gridSize: 13)) { afterLarge = ThemeEngine.shared.valueFont }

        #expect(afterSmall == afterLarge)
    }
}
