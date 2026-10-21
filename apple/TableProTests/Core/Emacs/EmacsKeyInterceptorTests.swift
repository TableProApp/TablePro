//
//  EmacsKeyInterceptorTests.swift
//  TableProTests
//

import AppKit
import Carbon.HIToolbox
@testable import TablePro
import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct EmacsKeyInterceptorTests {
    private let controller: TextViewController
    private let interceptor: EmacsKeyInterceptor

    init() {
        controller = EditorControllerFixture.make(string: "SELECT id FROM users\nWHERE id = 1")
        interceptor = EmacsKeyInterceptor(inlineSuggestionManager: nil)
        interceptor.install(controller: controller)
        caret(at: 0)
    }

    private var textView: TextView { controller.textView }

    private func caret(at location: Int) {
        textView.selectionManager.setSelectedRange(NSRange(location: location, length: 0))
    }

    private var selection: [NSRange] {
        textView.selectionManager.textSelections.map { $0.range }
    }

    @discardableResult
    private func press(
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags,
        keyCode: Int = 0
    ) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
        return interceptor.handleKeyDown(event) == nil
    }

    @Test("Ctrl+F, Ctrl+B, Option+F, Ctrl+E and Ctrl+A move the caret")
    func motions() throws {
        try press("f", .control)
        #expect(selection == [NSRange(location: 1, length: 0)])
        try press("b", .control)
        #expect(selection == [NSRange(location: 0, length: 0)])
        try press("f", .option)
        #expect(selection == [NSRange(location: 6, length: 0)])
        try press("e", .control)
        #expect(selection == [NSRange(location: 20, length: 0)])
        try press("a", .control)
        #expect(selection == [NSRange(location: 0, length: 0)])
        try press("n", .control)
        #expect(selection.first?.location == 21)
    }

    @Test("Ctrl+Space sets the mark and motions grow the region from it, either way")
    func markExtendsRegion() throws {
        caret(at: 7)
        try press(" ", .control, keyCode: kVK_Space)
        try press("f", .option)
        #expect(selection == [NSRange(location: 7, length: 2)])
        try press("b", .control)
        try press("b", .control)
        try press("b", .control)
        #expect(selection == [NSRange(location: 6, length: 1)])
        try press("", [], keyCode: kVK_RightArrow)
        #expect(selection == [NSRange(location: 7, length: 0)])
    }

    @Test("Ctrl+W kills the region and Ctrl+Y yanks it back")
    func killRegionAndYank() throws {
        caret(at: 7)
        try press(" ", .control, keyCode: kVK_Space)
        try press("f", .option)
        try press("w", .control)
        #expect(textView.string == "SELECT  FROM users\nWHERE id = 1")
        caret(at: 0)
        try press("y", .control)
        #expect(textView.string == "idSELECT  FROM users\nWHERE id = 1")
    }

    @Test("Option+W copies the region, ends it and leaves the text alone")
    func copyRegion() throws {
        caret(at: 0)
        try press(" ", .control, keyCode: kVK_Space)
        try press("f", .option)
        try press("w", .option)
        #expect(textView.string == "SELECT id FROM users\nWHERE id = 1")
        #expect(selection == [NSRange(location: 6, length: 0)])
        try press("f", .control)
        #expect(selection == [NSRange(location: 7, length: 0)])
        try press("y", .control)
        #expect(textView.string == "SELECT SELECTid FROM users\nWHERE id = 1")
    }

    @Test("Ctrl+G ends the region at point")
    func quitEndsRegion() throws {
        caret(at: 0)
        try press(" ", .control, keyCode: kVK_Space)
        try press("e", .control)
        #expect(selection == [NSRange(location: 0, length: 20)])
        try press("g", .control)
        #expect(selection == [NSRange(location: 20, length: 0)])
        try press("b", .control)
        #expect(selection == [NSRange(location: 19, length: 0)])
    }

    @Test("A selection change from outside ends the region")
    func outsideChangeEndsRegion() throws {
        caret(at: 0)
        try press(" ", .control, keyCode: kVK_Space)
        try press("f", .control)
        caret(at: 10)
        try press("f", .control)
        #expect(selection == [NSRange(location: 11, length: 0)])
        #expect(try press("", [], keyCode: kVK_RightArrow) == false)
    }

    @Test("A click where the caret already is still ends the region")
    func clickInPlaceEndsRegion() throws {
        caret(at: 0)
        try press(" ", .control, keyCode: kVK_Space)
        caret(at: 0)
        try press("f", .control)
        #expect(selection == [NSRange(location: 1, length: 0)])
    }

    @Test("Ctrl+K with an active region kills from point, not the region")
    func killLineLeavesRegion() throws {
        caret(at: 0)
        try press(" ", .control, keyCode: kVK_Space)
        try press("f", .option)
        try press("k", .control)
        #expect(textView.string == "SELECT\nWHERE id = 1")
    }

    @Test("Option+D kills words in a row into one entry; Ctrl+Y and Option+Y walk the ring")
    func killWordsAndYankPop() throws {
        caret(at: 0)
        try press("d", .option)
        try press("d", .option)
        #expect(textView.string == " FROM users\nWHERE id = 1")
        try press("e", .control)
        try press("", .option, keyCode: kVK_Delete)
        #expect(textView.string == " FROM \nWHERE id = 1")
        try press("y", .control)
        #expect(textView.string == " FROM users\nWHERE id = 1")
        try press("y", .option)
        #expect(textView.string == " FROM SELECT id\nWHERE id = 1")
    }

    @Test("Keys Emacs mode does not bind stay with the text view")
    func unboundKeysPassThrough() throws {
        #expect(try press("t", .control) == false)
        #expect(try press("l", .option) == false)
        #expect(try press("x", []) == false)
        #expect(try press("f", .command) == false)
    }

    @Test("An uninstalled interceptor claims nothing")
    func uninstalledClaimsNothing() throws {
        interceptor.uninstall()
        #expect(try press("f", .control) == false)
    }
}
