//
//  EmacsKeyResolverTests.swift
//  TableProTests
//

import AppKit
import Carbon.HIToolbox
@testable import TablePro
import Testing

struct EmacsKeyResolverTests {
    private func command(
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags,
        keyCode: Int = 0,
        markActive: Bool = false
    ) -> EmacsCommand? {
        EmacsKeyResolver.command(
            for: EmacsKeystroke(keyCode: keyCode, charactersIgnoringModifiers: key, modifiers: modifiers),
            markActive: markActive
        )
    }

    @Test(
        "Control keys",
        arguments: [
            ("a", EmacsCommand.move(.beginningOfLine)),
            ("e", .move(.endOfLine)),
            ("f", .move(.forwardChar)),
            ("b", .move(.backwardChar)),
            ("n", .move(.nextLine)),
            ("p", .move(.previousLine)),
            ("k", .killLine),
            ("y", .yank),
            ("w", .killRegion),
            ("g", .quit),
            (" ", .setMark)
        ]
    )
    func controlKeys(_ key: String, _ expected: EmacsCommand) {
        #expect(command(key, .control) == expected)
    }

    @Test(
        "Option is Meta for the bound keys",
        arguments: [
            ("f", EmacsCommand.move(.forwardWord)),
            ("b", .move(.backwardWord)),
            ("d", .killWord),
            ("y", .yankPop),
            ("w", .copyRegion)
        ]
    )
    func metaKeys(_ key: String, _ expected: EmacsCommand) {
        #expect(command(key, .option) == expected)
    }

    @Test("Option+Delete kills the word before the caret")
    func optionDelete() {
        #expect(command("\u{7f}", .option, keyCode: kVK_Delete) == .backwardKillWord)
    }

    @Test("Ctrl+Space and Ctrl+@ set the mark, whatever the Space key types")
    func setMark() {
        #expect(command("\0", .control, keyCode: kVK_Space) == .setMark)
        #expect(command("@", [.control, .shift], keyCode: kVK_ANSI_2) == .setMark)
    }

    @Test("Option on an unbound key still types the character it makes")
    func unboundOptionKeysPassThrough() {
        #expect(command("l", .option) == nil)
        #expect(command("5", .option) == nil)
        #expect(command("e", .option) == nil)
    }

    @Test("Command chords, shifted chords and unbound Control keys pass through")
    func otherChordsPassThrough() {
        #expect(command("f", [.command]) == nil)
        #expect(command("f", [.control, .command]) == nil)
        #expect(command("f", [.control, .option]) == nil)
        #expect(command("F", [.control, .shift]) == nil)
        #expect(command("F", [.option, .shift]) == nil)
        #expect(command("t", .control) == nil)
        #expect(command("d", .control) == nil)
        #expect(command("f", []) == nil)
    }

    @Test("Caps Lock, Function and the keypad flag do not change a chord")
    func ignoredFlags() {
        #expect(command("F", [.control, .capsLock]) == .move(.forwardChar))
        #expect(command("", [.numericPad, .function], keyCode: kVK_RightArrow, markActive: true) == .move(.forwardChar))
    }

    @Test("The arrows extend an active region and are left alone otherwise")
    func arrows() {
        #expect(command("", [], keyCode: kVK_LeftArrow, markActive: true) == .move(.backwardChar))
        #expect(command("", [], keyCode: kVK_RightArrow, markActive: true) == .move(.forwardChar))
        #expect(command("", [], keyCode: kVK_UpArrow, markActive: true) == .move(.previousLine))
        #expect(command("", [], keyCode: kVK_DownArrow, markActive: true) == .move(.nextLine))
        #expect(command("", [], keyCode: kVK_LeftArrow, markActive: false) == nil)
        #expect(command("", .shift, keyCode: kVK_LeftArrow, markActive: true) == nil)
    }
}
