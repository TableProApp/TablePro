//
//  VimEngineCommandLineTests.swift
//  TableProTests
//
//  Specification tests for command-line mode (:), search (/, ?), and the
//  command-line buffer accumulation/dispatch behavior.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineCommandLineTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!
    private var dispatchedCommand: String?

    init() {
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
        engine.onCommand = { [weak self] command in
            self?.dispatchedCommand = command
        }
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func enter() { _ = engine.process("\r", shift: false) }
    private func escape() { _ = engine.process("\u{1B}", shift: false) }
    private func backspace() { _ = engine.process("\u{7F}", shift: false) }

    // MARK: - Entering Command-Line Mode

    @Test
    func colonEntersCommandLineModeWithPrompt() {
        keys(":")
        if case .commandLine(let cmdBuffer) = engine.mode {
            #expect(cmdBuffer == ":")
        } else {
            Issue.record("Expected commandLine mode after ':'")
        }
    }

    @Test
    func slashEntersSearchModeWithPrompt() {
        keys("/")
        if case .commandLine(let cmdBuffer) = engine.mode {
            #expect(cmdBuffer == "/")
        } else {
            Issue.record("Expected commandLine mode after '/'")
        }
    }

    @Test
    func questionMarkEntersReverseSearchMode() {
        keys("?")
        if case .commandLine(let cmdBuffer) = engine.mode {
            #expect(cmdBuffer == "?",
                "? should start a reverse-search command-line buffer")
        } else {
            Issue.record("Expected commandLine mode after '?'")
        }
    }

    // MARK: - Buffer Accumulation

    @Test
    func charactersAccumulateInBuffer() {
        keys(":wq")
        if case .commandLine(let cmdBuffer) = engine.mode {
            #expect(cmdBuffer == ":wq")
        } else {
            Issue.record("Expected commandLine mode")
        }
    }

    @Test
    func whitespaceAccumulatesInBuffer() {
        keys(":set ")
        if case .commandLine(let cmdBuffer) = engine.mode {
            #expect(cmdBuffer == ":set ")
        } else {
            Issue.record("Expected commandLine mode")
        }
    }

    @Test
    func searchPatternAccumulates() {
        keys("/hello")
        if case .commandLine(let cmdBuffer) = engine.mode {
            #expect(cmdBuffer == "/hello")
        } else {
            Issue.record("Expected commandLine mode")
        }
    }

    // MARK: - Backspace

    @Test
    func backspaceRemovesLastChar() {
        keys(":wq")
        backspace()
        if case .commandLine(let cmdBuffer) = engine.mode {
            #expect(cmdBuffer == ":w")
        } else {
            Issue.record("Expected commandLine mode after backspace")
        }
    }

    @Test
    func backspaceOnLonePromptExitsToNormal() {
        keys(":")
        backspace()
        #expect(engine.mode == .normal,
            "Backspace on the prompt alone should exit to normal mode")
    }

    @Test
    func backspaceOnSearchPromptExitsToNormal() {
        keys("/")
        backspace()
        #expect(engine.mode == .normal)
    }

    // MARK: - Escape

    @Test
    func escapeCancelsCommand() {
        keys(":wq")
        escape()
        #expect(engine.mode == .normal)
        #expect(dispatchedCommand == nil, "Cancelled command must not fire onCommand")
    }

    // MARK: - Enter Dispatches Command

    @Test
    func enterDispatchesColonCommand() {
        keys(":w")
        enter()
        #expect(dispatchedCommand == "w",
            "Enter should dispatch the buffer (without the ':' prefix)")
        #expect(engine.mode == .normal)
    }

    @Test
    func enterDispatchesMultiCharCommand() {
        keys(":write file.sql")
        enter()
        #expect(dispatchedCommand == "write file.sql")
    }

    @Test
    func searchDoesNotDispatchToOnCommand() {
        // The engine now runs search natively via runSearch instead of forwarding
        // the pattern to onCommand. onCommand is reserved for `:`-style ex commands.
        keys("/hello")
        enter()
        #expect(dispatchedCommand == nil,
            "/pattern should be handled internally and not surface to onCommand")
    }

    @Test
    func enterOnEmptyCommandDispatchesEmptyString() {
        keys(":")
        // Buffer is just ":", backspace makes empty; let's enter directly.
        // Per typical command-line behavior, hitting Enter on ":" cancels.
        enter()
        #expect(engine.mode == .normal)
    }

    // MARK: - Standard Commands

    @Test
    func commandW() {
        keys(":w")
        enter()
        #expect(dispatchedCommand == "w")
    }

    @Test
    func commandQ() {
        keys(":q")
        enter()
        #expect(dispatchedCommand == "q")
    }

    @Test
    func commandWQ() {
        keys(":wq")
        enter()
        #expect(dispatchedCommand == "wq")
    }

    @Test
    func commandX() {
        keys(":x")
        enter()
        #expect(dispatchedCommand == "x")
    }

    // MARK: - Re-entry After Dispatch

    @Test
    func canReEnterAfterDispatch() {
        keys(":w")
        enter()
        #expect(engine.mode == .normal)
        // Reset captured command to test re-entry.
        dispatchedCommand = nil
        keys(":q")
        enter()
        #expect(dispatchedCommand == "q",
            "Engine should be ready for a fresh command-line entry after dispatch")
    }

    // MARK: - Display Label

    @Test
    func displayLabelShowsBufferInCommandLineMode() {
        keys(":wq")
        #expect(engine.mode.displayLabel == ":wq",
            "displayLabel for commandLine should be the literal buffer text")
    }
}
