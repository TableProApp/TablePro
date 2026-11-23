// The editor runs its typing filters on every edit it is not told is a command: an open bracket wraps a selection,
// deleting one takes its closer, a quote doubles. Vim's edits are commands, so they land exactly as the engine asks.

import AppKit
@testable import TablePro
import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct VimTextBufferAdapterCommandEditTests {
    private func run(_ keys: String, on text: String, at offset: Int) -> String {
        let controller = EditorControllerFixture.make(string: text)
        let adapter = VimTextBufferAdapter(controller: controller)
        let engine = VimEngine(buffer: adapter)
        return withExtendedLifetime(controller) {
            adapter.setSelectedRange(NSRange(location: offset, length: 0))
            for key in keys {
                _ = engine.process(key, shift: key.isUppercase)
            }
            return controller.textView.string
        }
    }

    @Test("x on an open bracket deletes that bracket only")
    func deleteOpenBracket() {
        #expect(run("x", on: "SELECT COUNT() FROM t", at: 12) == "SELECT COUNT) FROM t")
    }

    @Test("r( replaces the character with a bracket and wraps nothing")
    func replaceWithBracket() {
        #expect(run("r(", on: "a x b", at: 2) == "a ( b")
    }

    @Test("~ on a quote leaves the quote as it is")
    func toggleCaseOnQuote() {
        #expect(run("~", on: "'abc'", at: 0) == "'abc'")
    }

    @Test("R types over a character with a quote, and adds no closing quote")
    func replaceModeQuote() {
        #expect(run("R'\u{1B}", on: "WHERE n = x", at: 10) == "WHERE n = '")
    }

    @Test("o opens an empty line and leaves the next line's indent alone")
    func openLineBelow() {
        #expect(run("o\u{1B}", on: "    a\n    b", at: 4) == "    a\n\n    b")
    }
}
