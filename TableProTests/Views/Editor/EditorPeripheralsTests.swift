//
//  EditorPeripheralsTests.swift
//  TableProTests
//

import CodeEditSourceEditor
import Foundation
import Testing
@testable import TablePro

/// A gutter can be shown without line numbers so it can host the fold rail alone, and that is what left a 30pt
/// column holding a 14pt control, blank whenever the document had nothing to fold. Every editor in the app builds
/// its peripherals here so the two can never be set apart again.
@Suite("Editor peripherals")
struct EditorPeripheralsTests {

    @Test("A gutter is shown exactly when line numbers are", arguments: [true, false])
    func gutterFollowsLineNumbers(lineNumbers: Bool) {
        for folding in [true, false] {
            let peripherals = EditorPeripherals.editor(lineNumbers: lineNumbers, folding: folding)

            #expect(peripherals.showGutter == lineNumbers)
            #expect(peripherals.showLineNumbers == lineNumbers)
        }
    }

    @Test("Folding decides the rail, not the gutter")
    func foldingDrivesTheRibbonOnly() {
        #expect(EditorPeripherals.editor(lineNumbers: true, folding: true).showFoldingRibbon)
        #expect(EditorPeripherals.editor(lineNumbers: true, folding: false).showFoldingRibbon == false)
    }

    @Test("Folds are still calculated when the reader hides the line numbers")
    func foldsSurviveHiddenLineNumbers() {
        let peripherals = EditorPeripherals.editor(lineNumbers: false, folding: true)

        #expect(peripherals.showGutter == false, "There is no gutter, so there are no chevrons to draw")
        #expect(
            peripherals.showFoldingRibbon,
            "The rail stays enabled so folds keep being calculated for the Query menu and the collapsed chips"
        )
    }

    @Test("A read-only preview only grows a gutter when folding gives it a reason to")
    func previewGutterFollowsFolding() {
        let folding = EditorPeripherals.preview(folding: true)
        #expect(folding.showGutter)
        #expect(folding.showLineNumbers)
        #expect(folding.showFoldingRibbon)

        let plain = EditorPeripherals.preview(folding: false)
        #expect(plain.showGutter == false)
        #expect(plain.showLineNumbers == false)
        #expect(plain.showFoldingRibbon == false)
    }

    @Test("Only the editor a reader works in sizes its gutter for a window")
    func onlyTheEditorReservesWindowRoom() {
        #expect(EditorPeripherals.editor(lineNumbers: true, folding: true).gutterFitsContent == false)
        #expect(EditorPeripherals.inline(lineNumbers: true, folding: true).gutterFitsContent)
        #expect(EditorPeripherals.preview(folding: true).gutterFitsContent)
    }

    @Test("The minimap is off everywhere")
    func minimapIsOff() {
        #expect(EditorPeripherals.editor(lineNumbers: true, folding: true).showMinimap == false)
        #expect(EditorPeripherals.inline(lineNumbers: true, folding: true).showMinimap == false)
    }

    @Test("Every editor reveals invisible characters unless the reader turned them off")
    func invisibleCharactersAreRevealed() {
        #expect(EditorPeripherals.editor(lineNumbers: true, folding: true).showSpecialCharacters)
        #expect(EditorPeripherals.inline(lineNumbers: true, folding: true).showSpecialCharacters)
        #expect(EditorPeripherals.preview(folding: false).showSpecialCharacters)
        let hidden = EditorPeripherals.editor(lineNumbers: true, folding: true, invisibleCharacters: false)
        #expect(hidden.showSpecialCharacters == false)
        #expect(EditorPeripherals.inline(lineNumbers: true, folding: true, invisibleCharacters: false)
            .showSpecialCharacters == false)
        #expect(EditorPeripherals.preview(folding: false, invisibleCharacters: false).showSpecialCharacters == false)
    }

    @Test("Settings saved before the option existed reveal invisible characters")
    func invisibleCharactersDefaultOn() throws {
        let decoded = try JSONDecoder().decode(EditorSettings.self, from: Data("{}".utf8))
        #expect(decoded.showInvisibleCharacters)
        #expect(EditorSettings.default.showInvisibleCharacters)
    }
}
