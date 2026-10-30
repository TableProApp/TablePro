//
//  VimEngineBlackHoleRegisterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct VimEngineBlackHoleRegisterTests {
        private func keys(_ chars: String, into engine: VimEngine) {
            for char in chars { _ = engine.process(char, shift: false) }
        }

        @Test(arguments: ["\"_dd", "\"_2dd", "\"_x", "\"_dw", "\"_yy", "\"_yw", "l\"_X", "\"_s", "\"_cc"])
        func writesNoRegisterAndNoClipboard(sequence: String) {
            let buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
            let engine = VimEngine(buffer: buffer)
            keys("yyj", into: engine)
            let numbered = engine.numberedRegisters.map { $0.text }

            keys(sequence, into: engine)

            #expect(engine.register.text == "one\n")
            #expect(engine.register.isLinewise)
            #expect(engine.numberedRegisters.map { $0.text } == numbered)
            #expect(engine.namedRegisters.isEmpty)
            #expect(RecordingClipboard.current?.writes == ["one\n"])
        }

        @Test
        func pasteAfterABlackHoleDeletePastesTheEarlierYank() {
            let buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
            let engine = VimEngine(buffer: buffer)
            keys("yyj\"_ddp", into: engine)
            #expect(buffer.text == "one\nthree\none\n")
        }

        @Test
        func theBlackHoleAppliesToOneCommandOnly() {
            let buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
            let engine = VimEngine(buffer: buffer)
            keys("yyj\"_dddd", into: engine)
            #expect(buffer.text == "one\n")
            #expect(engine.register.text == "three\n")
            #expect(RecordingClipboard.current?.writes == ["one\n", "three\n"])
        }
    }
}
