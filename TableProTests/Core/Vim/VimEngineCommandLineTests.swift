//
//  VimEngineCommandLineTests.swift
//  TableProTests
//
//  Specification tests for command-line mode (:), search (/, ?), and the
//  command-line buffer accumulation/dispatch behavior.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineCommandLineTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!
    private var dispatchedCommand: String?

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
        engine.onCommand = { [weak self] command in
            self?.dispatchedCommand = command
        }
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        dispatchedCommand = nil
        super.tearDown()
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func enter() { _ = engine.process("\r", shift: false) }
    private func escape() { _ = engine.process("\u{1B}", shift: false) }
    private func backspace() { _ = engine.process("\u{7F}", shift: false) }

    // MARK: - Entering Command-Line Mode

    func testColonEntersCommandLineModeWithPrompt() {
        keys(":")
        if case .commandLine(let cmdBuffer) = engine.mode {
            XCTAssertEqual(cmdBuffer, ":")
        } else {
            XCTFail("Expected commandLine mode after ':'")
        }
    }

    func testSlashEntersSearchModeWithPrompt() {
        keys("/")
        if case .commandLine(let cmdBuffer) = engine.mode {
            XCTAssertEqual(cmdBuffer, "/")
        } else {
            XCTFail("Expected commandLine mode after '/'")
        }
    }

    func testQuestionMarkEntersReverseSearchMode() {
        keys("?")
        if case .commandLine(let cmdBuffer) = engine.mode {
            XCTAssertEqual(cmdBuffer, "?",
                "? should start a reverse-search command-line buffer")
        } else {
            XCTFail("Expected commandLine mode after '?'")
        }
    }

    // MARK: - Buffer Accumulation

    func testCharactersAccumulateInBuffer() {
        keys(":wq")
        if case .commandLine(let cmdBuffer) = engine.mode {
            XCTAssertEqual(cmdBuffer, ":wq")
        } else {
            XCTFail("Expected commandLine mode")
        }
    }

    func testWhitespaceAccumulatesInBuffer() {
        keys(":set ")
        if case .commandLine(let cmdBuffer) = engine.mode {
            XCTAssertEqual(cmdBuffer, ":set ")
        } else {
            XCTFail("Expected commandLine mode")
        }
    }

    func testSearchPatternAccumulates() {
        keys("/hello")
        if case .commandLine(let cmdBuffer) = engine.mode {
            XCTAssertEqual(cmdBuffer, "/hello")
        } else {
            XCTFail("Expected commandLine mode")
        }
    }

    // MARK: - Backspace

    func testBackspaceRemovesLastChar() {
        keys(":wq")
        backspace()
        if case .commandLine(let cmdBuffer) = engine.mode {
            XCTAssertEqual(cmdBuffer, ":w")
        } else {
            XCTFail("Expected commandLine mode after backspace")
        }
    }

    func testBackspaceOnLonePromptExitsToNormal() {
        keys(":")
        backspace()
        XCTAssertEqual(engine.mode, .normal,
            "Backspace on the prompt alone should exit to normal mode")
    }

    func testBackspaceOnSearchPromptExitsToNormal() {
        keys("/")
        backspace()
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - Escape

    func testEscapeCancelsCommand() {
        keys(":wq")
        escape()
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertNil(dispatchedCommand, "Cancelled command must not fire onCommand")
    }

    // MARK: - Enter Dispatches Command

    func testEnterDispatchesColonCommand() {
        keys(":w")
        enter()
        XCTAssertEqual(dispatchedCommand, "w",
            "Enter should dispatch the buffer (without the ':' prefix)")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testEnterDispatchesMultiCharCommand() {
        keys(":write file.sql")
        enter()
        XCTAssertEqual(dispatchedCommand, "write file.sql")
    }

    func testSearchDoesNotDispatchToOnCommand() {
        // The engine now runs search natively via runSearch instead of forwarding
        // the pattern to onCommand. onCommand is reserved for `:`-style ex commands.
        keys("/hello")
        enter()
        XCTAssertNil(dispatchedCommand,
            "/pattern should be handled internally and not surface to onCommand")
    }

    func testEnterOnEmptyCommandDispatchesEmptyString() {
        keys(":")
        // Buffer is just ":", backspace makes empty; let's enter directly.
        // Per typical command-line behavior, hitting Enter on ":" cancels.
        enter()
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - Standard Commands

    func testCommandW() {
        keys(":w")
        enter()
        XCTAssertEqual(dispatchedCommand, "w")
    }

    func testCommandQ() {
        keys(":q")
        enter()
        XCTAssertEqual(dispatchedCommand, "q")
    }

    func testCommandWQ() {
        keys(":wq")
        enter()
        XCTAssertEqual(dispatchedCommand, "wq")
    }

    func testCommandX() {
        keys(":x")
        enter()
        XCTAssertEqual(dispatchedCommand, "x")
    }

    // MARK: - Re-entry After Dispatch

    func testCanReEnterAfterDispatch() {
        keys(":w")
        enter()
        XCTAssertEqual(engine.mode, .normal)
        // Reset captured command to test re-entry.
        dispatchedCommand = nil
        keys(":q")
        enter()
        XCTAssertEqual(dispatchedCommand, "q",
            "Engine should be ready for a fresh command-line entry after dispatch")
    }

    // MARK: - Display Label

    func testDisplayLabelShowsBufferInCommandLineMode() {
        keys(":wq")
        XCTAssertEqual(engine.mode.displayLabel, ":wq",
            "displayLabel for commandLine should be the literal buffer text")
    }
}
