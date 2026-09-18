//
//  VimKeyRouteResolverTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("VimKeyRouteResolver")
struct VimKeyRouteResolverTests {
    private static let outsideInsertModes: [VimMode] = [
        .normal,
        .visual(linewise: false),
        .visual(linewise: true),
        .commandLine(buffer: ":")
    ]
    private static let normalAndVisualModes: [VimMode] = [.normal, .visual(linewise: false), .visual(linewise: true)]
    private static let insertModes: [VimMode] = [.insert, .replace]
    private static let everyMode: [VimMode] = outsideInsertModes + insertModes

    private static let controlLetters: [(characters: String, key: String)] = [
        ("\u{01}", "a"), ("\u{03}", "c"), ("\u{04}", "d"), ("\u{08}", "h"), ("\u{0B}", "k"), ("\u{0E}", "n"),
        ("\u{0F}", "o"), ("\u{10}", "p"), ("\u{12}", "r"), ("\u{14}", "t"), ("\u{15}", "u"), ("\u{18}", "x"),
        ("\u{19}", "y")
    ]

    private func route(
        _ characters: String,
        key: String? = nil,
        _ modifiers: NSEvent.ModifierFlags = [],
        in mode: VimMode,
        keypadEnter: Bool = false
    ) -> VimKeyRoute {
        let keystroke = VimKeystroke(
            characters: characters,
            charactersIgnoringModifiers: key ?? characters,
            modifiers: modifiers,
            isKeypadEnter: keypadEnter
        )
        return VimKeyRouteResolver.route(keystroke, in: mode)
    }

    @Test("Ctrl+D reaches the engine in Normal mode instead of deleting forward")
    func controlDReachesTheEngine() {
        #expect(route("\u{04}", key: "d", .control, in: .normal) == .engine("\u{04}"))
    }

    @Test("Every Control chord that edits in AppKit reaches the engine outside Insert mode")
    func editingControlChordsReachTheEngine() {
        for mode in Self.outsideInsertModes {
            for (control, key) in Self.controlLetters {
                #expect(route(control, key: key, .control, in: mode) == .engine(Character(control)))
                #expect(route(control, key: key.uppercased(), [.control, .shift], in: mode) == .engine(Character(control)))
            }
            #expect(route("\u{7F}", .control, in: mode) == .engine("\u{7F}"))
        }
    }

    @Test("Control chords that type no character stay with the menus outside Insert mode")
    func nonTypingControlChordsStayWithTheTextView() {
        let chords: [(characters: String, key: String)] = [
            ("1", "1"), ("/", "/"), ("\r", "\r"), ("\t", "i"), ("\r", "m"), ("\n", "j")
        ]
        for mode in Self.outsideInsertModes {
            for (characters, key) in chords {
                #expect(route(characters, key: key, .control, in: mode) == .textView)
            }
        }
    }

    @Test("Ctrl+Space, Ctrl+Tab and Ctrl+Shift+Tab stay with the text view in every mode")
    func controlSpaceAndTabStayWithTheTextView() {
        for mode in Self.everyMode {
            #expect(route("\u{00}", key: " ", .control, in: mode) == .textView)
            #expect(route("\t", key: "\t", .control, in: mode) == .textView)
            #expect(route("\u{19}", key: "\u{19}", [.control, .shift], in: mode) == .textView)
        }
    }

    @Test("Ctrl+Y and Ctrl+Shift+Tab share a character but only Ctrl+Y reaches the engine")
    func controlYIsNotControlShiftTab() {
        for mode in Self.outsideInsertModes {
            #expect(route("\u{19}", key: "y", .control, in: mode) == .engine("\u{19}"))
            #expect(route("\u{19}", key: "\u{19}", [.control, .shift], in: mode) == .textView)
        }
    }

    @Test("Shift+Tab is never read as Ctrl+Y")
    func shiftTabIsNotControlY() {
        for mode in Self.outsideInsertModes + [.replace] {
            #expect(route("\u{19}", key: "\u{19}", .shift, in: mode) == .discard)
            #expect(route("\u{19}", key: "\u{19}", [.control, .option, .shift], in: mode) == .discard)
        }
        #expect(route("\u{19}", key: "\u{19}", .shift, in: .insert) == .textView)
    }

    @Test("Ctrl+Option+Space and Ctrl+Option+Tab type a character, so the text view never gets them outside Insert")
    func controlOptionSpaceAndTabReachTheEngine() {
        for mode in Self.outsideInsertModes {
            #expect(route("\u{00}", key: " ", [.control, .option], in: mode) == .engine("\u{00}"))
            #expect(route("\t", key: "\t", [.control, .option], in: mode) == .engine("\t"))
        }
    }

    @Test("Option chords that type text reach the engine outside Insert mode")
    func optionTextReachesTheEngine() {
        let chords: [(characters: String, key: String)] = [
            ("\u{02D9}", "h"), ("\u{00A0}", " "), ("[", "5"), ("@", "l"), ("~", "n"), ("\u{7F}", "\u{7F}")
        ]
        for mode in Self.outsideInsertModes {
            for (characters, key) in chords {
                #expect(route(characters, key: key, .option, in: mode) == .engine(Character(characters)))
            }
            #expect(route("\u{2021}", key: "7", [.option, .shift], in: mode) == .engine("\u{2021}"))
        }
    }

    @Test("Control+Option chords that type text reach the engine outside Insert mode")
    func controlOptionTextReachesTheEngine() {
        for mode in Self.outsideInsertModes {
            #expect(route("\u{2202}", key: "d", [.control, .option], in: mode) == .engine("\u{2202}"))
            #expect(route("\u{04}", key: "d", [.control, .option], in: mode) == .engine("\u{04}"))
        }
    }

    @Test("A dead key never starts a composition outside Insert mode")
    func deadKeyIsDiscardedOutsideInsertMode() {
        for mode in Self.outsideInsertModes {
            #expect(route("", .option, in: mode) == .discard)
            #expect(route("", [], in: mode) == .discard)
        }
        for mode in Self.insertModes {
            #expect(route("", .option, in: mode) == .textView)
        }
    }

    @Test("Command shortcuts always reach the text view")
    func commandShortcutsStayWithTheTextView() {
        for mode in Self.everyMode {
            #expect(route("c", .command, in: mode) == .textView)
            #expect(route("v", [.command, .shift], in: mode) == .textView)
            #expect(route("\u{06}", key: "f", [.command, .control], in: mode) == .textView)
            #expect(route("\u{0192}", [.command, .option], in: mode) == .textView)
        }
    }

    @Test("Arrow keys become hjkl motions in Normal and Visual mode")
    func arrowsBecomeMotions() {
        let arrows: [(String, Character)] = [("\u{F700}", "k"), ("\u{F701}", "j"), ("\u{F702}", "h"), ("\u{F703}", "l")]
        for mode in Self.normalAndVisualModes {
            for (arrow, motion) in arrows {
                #expect(route(arrow, [.function, .numericPad], in: mode) == .engine(motion))
                #expect(route(arrow, [.function, .numericPad, .shift], in: mode) == .engine(motion))
            }
        }
    }

    @Test("Option and Control arrows stay native navigation")
    func modifiedArrowsStayWithTheTextView() {
        for mode in Self.normalAndVisualModes {
            #expect(route("\u{F702}", [.function, .numericPad, .option], in: mode) == .textView)
            #expect(route("\u{F703}", [.function, .numericPad, .control], in: mode) == .textView)
        }
    }

    @Test("Forward Delete deletes like x in Normal and Visual mode")
    func forwardDeleteBecomesX() {
        for mode in Self.normalAndVisualModes {
            #expect(route("\u{F728}", .function, in: mode) == .engine("x"))
        }
    }

    @Test("A modified Forward Delete never edits outside Insert mode")
    func modifiedForwardDeleteIsDiscarded() {
        for mode in Self.outsideInsertModes {
            #expect(route("\u{F728}", [.function, .option], in: mode) == .discard)
            #expect(route("\u{F728}", [.function, .control], in: mode) == .discard)
        }
    }

    @Test("The command line takes no arrow or Forward Delete")
    func commandLineDiscardsEditingFunctionKeys() {
        let mode = VimMode.commandLine(buffer: ":")
        #expect(route("\u{F700}", [.function, .numericPad], in: mode) == .discard)
        #expect(route("\u{F728}", .function, in: mode) == .discard)
    }

    @Test("Other function keys stay with the text view")
    func otherFunctionKeysStayWithTheTextView() {
        for mode in Self.everyMode {
            for key in ["\u{F729}", "\u{F72B}", "\u{F72C}", "\u{F708}"] {
                #expect(route(key, .function, in: mode) == .textView)
            }
        }
    }

    @Test("Keypad Enter reaches the engine as Return, apart from Ctrl+C that shares its character")
    func keypadEnterIsReturn() {
        #expect(route("\u{03}", .numericPad, in: .normal, keypadEnter: true) == .engine("\r"))
        #expect(route("\u{03}", key: "c", .control, in: .normal) == .engine("\u{03}"))
    }

    @Test("Insert and Replace mode send the Vim insert controls to the engine")
    func insertControlsReachTheEngine() {
        let controls: [(characters: String, key: String)] = [
            ("\u{17}", "w"), ("\u{15}", "u"), ("\u{14}", "t"), ("\u{04}", "d"), ("\u{1B}", "[")
        ]
        for mode in Self.insertModes {
            for (control, key) in controls {
                #expect(route(control, key: key, .control, in: mode) == .engine(Character(control)))
            }
        }
    }

    @Test("Insert mode leaves Ctrl+H and Ctrl+Delete to the text view, which deletes every selection")
    func insertModeBackspaceChordsStayWithTheTextView() {
        #expect(route("\u{08}", key: "h", .control, in: .insert) == .textView)
        #expect(route("\u{7F}", .control, in: .insert) == .textView)
    }

    @Test("Replace mode sends Ctrl+H and Ctrl+Delete to the engine, which restores the overwritten text")
    func replaceModeBackspaceChordsReachTheEngine() {
        #expect(route("\u{08}", key: "h", .control, in: .replace) == .engine("\u{08}"))
        #expect(route("\u{7F}", .control, in: .replace) == .engine("\u{7F}"))
    }

    @Test("Insert and Replace mode leave every other Control chord to the text view")
    func otherControlChordsStayWithTheTextViewInInsertMode() {
        let chords: [(characters: String, key: String)] = [
            ("\u{01}", "a"), ("\u{05}", "e"), ("\u{0B}", "k"), ("\u{12}", "r"), ("\u{00}", " "), ("\t", "\t")
        ]
        for mode in Self.insertModes {
            for (characters, key) in chords {
                #expect(route(characters, key: key, .control, in: mode) == .textView)
            }
            #expect(route("\u{04}", key: "d", [.control, .option], in: mode) == .textView)
        }
    }

    @Test("Option chords type text in Insert mode and overwrite in Replace mode")
    func optionTextInInsertModes() {
        #expect(route("\u{02D9}", .option, in: .insert) == .textView)
        #expect(route("\u{02D9}", .option, in: .replace) == .engine("\u{02D9}"))
    }

    @Test("Function keys stay native in Insert and Replace mode")
    func functionKeysStayNativeInInsertModes() {
        for mode in Self.insertModes {
            #expect(route("\u{F700}", [.function, .numericPad], in: mode) == .textView)
            #expect(route("\u{F728}", .function, in: mode) == .textView)
        }
    }

    @Test("Plain keys reach the engine in every mode")
    func plainKeysReachTheEngine() {
        for mode in Self.everyMode {
            #expect(route("j", in: mode) == .engine("j"))
            #expect(route("J", .shift, in: mode) == .engine("J"))
        }
    }
}
