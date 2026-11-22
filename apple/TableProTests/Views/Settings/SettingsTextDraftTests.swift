import Foundation
@testable import TablePro
import Testing

struct SettingsTextDraftTests {
    // Drives a draft the way SettingsNumberField does: a write only on commit, then a read-back.
    private struct NumberFieldHarness {
        var stored: Int
        var draft: SettingsTextDraft
        var writes: [Int] = []
        let range: ClosedRange<Int>
        let invalid: SettingsInvalidEntry

        init(stored: Int, range: ClosedRange<Int>, invalid: SettingsInvalidEntry) {
            self.stored = stored
            self.range = range
            self.invalid = invalid
            draft = SettingsTextDraft(SettingsFormat.identifier(stored))
        }

        mutating func type(_ text: String) {
            draft.text = text
            draft.clearError(ifResolvedBy: resolve)
        }

        mutating func commit() {
            if let committed = draft.commit(to: stored, resolve: resolve) {
                stored = committed
                writes.append(committed)
            }
            if draft.error == nil {
                draft.settle(to: SettingsFormat.identifier(stored))
            }
        }

        mutating func remoteChange(_ value: Int) {
            stored = value
            draft.resync(to: SettingsFormat.identifier(value))
        }

        private func resolve(_ text: String) -> SettingsDraftResolution<Int> {
            SettingsIntegerInput.resolve(text, in: range, invalid: invalid)
        }
    }

    @Test("Typing writes nothing, and Return then focus loss writes the final value once")
    func commitsOnceWithTheFinalValue() {
        var field = NumberFieldHarness(stored: 23508, range: 1024...65535, invalid: .reject("Choose a port from 1024 to 65535."))
        for text in ["2", "23", "235", "2350", "23509"] {
            field.type(text)
        }
        #expect(field.writes.isEmpty)

        field.commit()
        field.commit()
        field.commit()

        #expect(field.writes == [23509])
        #expect(field.draft.text == "23509")
        #expect(!field.draft.isEdited)
    }

    @Test("An untouched draft follows a remote change and never writes over it")
    func untouchedDraftNeverOverwritesRemoteChange() {
        var field = NumberFieldHarness(stored: 500, range: 1...10000, invalid: .clamp)
        field.remoteChange(800)
        field.commit()

        #expect(field.writes.isEmpty)
        #expect(field.stored == 800)
        #expect(field.draft.text == "800")
    }

    @Test("A commit before the remote change reaches the draft writes nothing")
    func untouchedCommitBeforeResyncWritesNothing() {
        var draft = SettingsTextDraft("NULL")
        let committed = draft.commit(to: "(null)") { .accept($0) }
        #expect(committed == nil)
    }

    @Test("An edited draft keeps the user's text when a remote change arrives")
    func editedDraftSurvivesRemoteChange() {
        var draft = SettingsTextDraft("NULL")
        draft.text = "nil"
        draft.resync(to: "(null)")

        #expect(draft.text == "nil")
        #expect(draft.seed == "(null)")
        let committed = draft.commit(to: "(null)") { .accept($0) }
        #expect(committed == "nil")
    }

    @Test("Escape restores the stored text and nothing is written")
    func escapeReverts() {
        var field = NumberFieldHarness(stored: 30, range: 1...300, invalid: .clamp)
        field.type("45")
        field.draft.revert()
        field.commit()

        #expect(field.draft.text == "30")
        #expect(field.writes.isEmpty)
    }

    @Test("Reject keeps the draft and shows the message, and a valid edit clears it")
    func rejectKeepsDraftAndError() {
        let message = "Choose a port from 1024 to 65535."
        var field = NumberFieldHarness(stored: 23508, range: 1024...65535, invalid: .reject(message))
        field.type("80")
        field.commit()

        #expect(field.writes.isEmpty)
        #expect(field.draft.text == "80")
        #expect(field.draft.error == message)

        field.type("8080")
        #expect(field.draft.error == nil)
        field.commit()
        #expect(field.writes == [8080])
    }

    @Test("Escape clears a rejection")
    func escapeClearsRejection() {
        var field = NumberFieldHarness(stored: 23508, range: 1024...65535, invalid: .reject("x"))
        field.type("abc")
        field.commit()
        #expect(field.draft.error == "x")

        field.draft.revert()
        #expect(field.draft.error == nil)
        #expect(field.draft.text == "23508")
    }

    @Test("Clamp writes the nearest bound once and shows it")
    func clampWritesBound() {
        var field = NumberFieldHarness(stored: 500, range: 1...10000, invalid: .clamp)
        field.type("50000")
        field.commit()

        #expect(field.writes == [10000])
        #expect(field.draft.text == "10000")
    }

    @Test("Clamp reverts text that is not a number")
    func clampRevertsUnparsableText() {
        var field = NumberFieldHarness(stored: 500, range: 1...10000, invalid: .clamp)
        field.type("5x")
        field.commit()

        #expect(field.writes.isEmpty)
        #expect(field.draft.text == "500")
    }

    @Test("A draft that parses to the stored value writes nothing and shows it plainly")
    func equalValueWritesNothing() {
        var field = NumberFieldHarness(stored: 500, range: 1...10000, invalid: .clamp)
        field.type(" 0500 ")
        field.commit()

        #expect(field.writes.isEmpty)
        #expect(field.draft.text == "500")
    }

    @Test(
        "Integer parsing takes only a sign and digits",
        arguments: [
            ("23509", 23509 as Int?),
            (" 80 ", 80),
            ("-5", -5),
            ("\u{0664}\u{0662}", 42),
            ("1,000", nil),
            ("1.000", nil),
            ("1e3", nil),
            ("80abc", nil),
            ("", nil),
            ("-", nil),
            ("99999999999999999999999", nil),
        ]
    )
    func parsesStrictly(text: String, expected: Int?) {
        #expect(SettingsIntegerInput.parse(text) == expected)
    }

    @Test("The text field commit normalizes and reverts invalid text")
    func textFieldResolution() {
        var draft = SettingsTextDraft("NULL")
        let resolve: (String) -> SettingsDraftResolution<String> = { text in
            text.trimmingCharacters(in: .whitespaces).isEmpty ? .revert : .accept(text.trimmingCharacters(in: .whitespaces))
        }

        draft.text = "   "
        let blank = draft.commit(to: "NULL", resolve: resolve)
        #expect(blank == nil)
        #expect(draft.text == "NULL")

        draft.text = " nil "
        let trimmed = draft.commit(to: "NULL", resolve: resolve)
        #expect(trimmed == "nil")
    }
}
