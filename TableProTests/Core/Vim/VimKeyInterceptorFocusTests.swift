//
//  VimKeyInterceptorFocusTests.swift
//  TableProTests
//
//  Regression tests for how VimKeyInterceptor claims keys from the editor's key chain
//

import AppKit
import Carbon.HIToolbox
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("VimKeyInterceptor key claims")
@MainActor
struct VimKeyInterceptorFocusTests {
    private func makeInterceptor(text: String = "SELECT * FROM users;") -> (VimEngine, VimKeyInterceptor) {
        let buffer = VimTextBufferMock(text: text)
        buffer.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        let engine = VimEngine(buffer: buffer)
        return (engine, VimKeyInterceptor(engine: engine, inlineSuggestionManager: nil))
    }

    private func keyDown(keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )
    }

    /// Without a controller the interceptor has no text view to ask about marked text, so it claims
    /// nothing rather than acting on a keystroke an input method may own.
    @Test("An interceptor with no controller claims nothing")
    func uninstalledInterceptorClaimsNothing() throws {
        let (engine, interceptor) = makeInterceptor()
        _ = engine.process("i", shift: false)
        let escape = try #require(keyDown(keyCode: kVK_Escape, characters: "\u{1b}"))

        #expect(interceptor.handleKeyDown(escape) === escape)
        #expect(engine.mode == .insert)
    }

    @Test("handleEscapeFromExternalSource returns false when engine already in normal mode")
    func externalEscapeNoopsInNormalMode() {
        let (engine, interceptor) = makeInterceptor(text: "hello")
        #expect(engine.mode == .normal)
        #expect(interceptor.handleEscapeFromExternalSource() == false)
        #expect(engine.mode == .normal)
    }

    @Test("handleEscapeFromExternalSource switches insert to normal and reports consumed")
    func externalEscapeSwitchesInsertToNormal() {
        let buffer = VimTextBufferMock(text: "SELECT * FROM users;")
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        let engine = VimEngine(buffer: buffer)
        let interceptor = VimKeyInterceptor(engine: engine, inlineSuggestionManager: nil)
        _ = engine.process("i", shift: false)
        #expect(engine.mode == .insert)
        #expect(interceptor.handleEscapeFromExternalSource() == true)
        #expect(engine.mode == .normal)
        #expect(buffer.selectedRange().location == 19)
    }

    @Test("handleEscapeFromExternalSource switches replace to normal")
    func externalEscapeSwitchesReplaceToNormal() {
        let (engine, interceptor) = makeInterceptor(text: "hello")
        _ = engine.process("R", shift: true)
        #expect(engine.mode == .replace)
        #expect(interceptor.handleEscapeFromExternalSource() == true)
        #expect(engine.mode == .normal)
    }
}
