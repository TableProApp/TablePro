import AppKit
import Foundation
@testable import TablePro
import TableProTextEngine
import Testing

private let thumbsUp = "\u{1F44D}"
private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
private let accented = "e\u{301}"
private let composedCharacters = [thumbsUp, family, accented]

private func units(_ text: String) -> Int {
    (text as NSString).length
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct VimEngineComposedCharacterTests {
        @MainActor
        private final class Session {
            let buffer: VimTextBufferMock
            let engine: VimEngine

            init(_ text: String, caret: Int) {
                buffer = VimTextBufferMock(text: text, selectedRange: NSRange(location: caret, length: 0))
                engine = VimEngine(buffer: buffer)
            }

            func press(_ keys: String) {
                for key in keys { _ = engine.process(key, shift: false) }
            }

            func escape() { _ = engine.process("\u{1B}", shift: false) }

            func backspace() { _ = engine.process("\u{7F}", shift: false) }

            // Insert mode leaves typing to the text view, which puts the text at the caret.
            func typeInTextView(_ text: String) {
                buffer.replaceCharacters(in: buffer.selectedRange(), with: text)
            }

            var text: String { buffer.text }
            var caret: Int { buffer.selectedRange().location }
            var selection: NSRange { buffer.selectedRange() }
        }

        // MARK: - x, X, s

        @Test(arguments: composedCharacters)
        func xDeletesTheWholeCharacter(character: String) {
            let session = Session("a\(character)b\n", caret: 1)
            session.press("x")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
            #expect(session.engine.register.text == character)
        }

        @Test
        func xOnAnEmojiInAStatement() {
            let session = Session("INSERT INTO notes VALUES ('ok \(thumbsUp)')\n", caret: 30)
            session.press("x")
            #expect(session.text == "INSERT INTO notes VALUES ('ok ')\n")
            #expect(session.caret == 30)
        }

        @Test
        func countedXDeletesWholeCharactersOfEachKind() {
            let session = Session("a\(thumbsUp)\(family)\(accented)z\n", caret: 1)
            session.press("3x")
            #expect(session.text == "az\n")
            #expect(session.caret == 1)
            #expect(session.engine.register.text == thumbsUp + family + accented)
        }

        @Test
        func xOnTheLastCharacterLandsOnTheStartOfTheNewLastOne() {
            let session = Session("a\(thumbsUp)\(thumbsUp)\n", caret: 3)
            session.press("x")
            #expect(session.text == "a\(thumbsUp)\n")
            #expect(session.caret == 1)
        }

        @Test(arguments: composedCharacters)
        func capitalXDeletesTheWholeCharacterBeforeTheCaret(character: String) {
            let session = Session("a\(character)b\n", caret: 1 + units(character))
            session.press("X")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
        }

        @Test
        func countedCapitalXDeletesWholeCharacters() {
            let session = Session("a\(family)\(accented)b\n", caret: 1 + units(family) + units(accented))
            session.press("2X")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
        }

        @Test(arguments: composedCharacters)
        func sSubstitutesTheWholeCharacter(character: String) {
            let session = Session("a\(character)b\n", caret: 1)
            session.press("s")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
            #expect(session.engine.mode == .insert)
        }

        // MARK: - r

        @Test(arguments: composedCharacters)
        func rReplacesTheWholeCharacter(character: String) {
            let session = Session("a\(character)b\n", caret: 1)
            session.press("r-")
            #expect(session.text == "a-b\n")
            #expect(session.caret == 1)
        }

        @Test
        func countedRReplacesEmojiByCharacter() {
            let session = Session("\(thumbsUp)\(thumbsUp)z\n", caret: 0)
            session.press("2r*")
            #expect(session.text == "**z\n")
            #expect(session.caret == 1)
        }

        @Test
        func rWithAnEmojiLeavesTheCaretOnTheLastOneWritten() {
            let session = Session("abcd\n", caret: 0)
            session.press("3r\(thumbsUp)")
            #expect(session.text == "\(thumbsUp)\(thumbsUp)\(thumbsUp)d\n")
            #expect(session.caret == 4)
        }

        @Test
        func rCountsCharactersLeftOnTheLine() {
            let refused = Session("a\(thumbsUp)\n", caret: 0)
            refused.press("3rx")
            #expect(refused.text == "a\(thumbsUp)\n", "Two characters remain, so 3r is refused")
            #expect(refused.caret == 0)

            let replaced = Session("a\(thumbsUp)\n", caret: 0)
            replaced.press("2rx")
            #expect(replaced.text == "xx\n")
            #expect(replaced.caret == 1)
        }

        // MARK: - ~

        @Test
        func tildeTogglesAcrossAnEmoji() {
            let session = Session("a\(thumbsUp)b\n", caret: 0)
            session.press("3~")
            #expect(session.text == "A\(thumbsUp)B\n")
            #expect(session.caret == 3)
        }

        @Test
        func tildeKeepsTheMarkOnItsLetter() {
            let session = Session("\(accented)x\n", caret: 0)
            session.press("~")
            #expect(session.text == "E\u{301}x\n")
            #expect(session.caret == 2)
        }

        @Test
        func tildeLandsAfterACaseChangeThatGrowsTheText() {
            let session = Session("\u{DF}a\n", caret: 0)
            session.press("~")
            #expect(session.text == "SSa\n")
            #expect(session.caret == 2)
        }

        // MARK: - h, l, $, j, e

        @Test
        func hAndLStepOneCharacterAtATime() {
            // a 0, thumbs up 1, b 3, family 4, c 12, space 13, accented e 14, x 16
            let session = Session("a\(thumbsUp)b\(family)c \(accented)x\n", caret: 0)
            var forward: [Int] = []
            for _ in 0..<8 {
                session.press("l")
                forward.append(session.caret)
            }
            #expect(forward == [1, 3, 4, 12, 13, 14, 16, 16])
            var backward: [Int] = []
            for _ in 0..<8 {
                session.press("h")
                backward.append(session.caret)
            }
            #expect(backward == [14, 13, 12, 4, 3, 1, 0, 0])
        }

        @Test
        func countedLAndHCrossSeveralCharacters() {
            let session = Session("a\(thumbsUp)b\(family)c \(accented)x\n", caret: 0)
            session.press("3l")
            #expect(session.caret == 4)
            session.press("$")
            session.press("3h")
            #expect(session.caret == 12)
        }

        @Test(arguments: composedCharacters)
        func dollarLandsOnTheStartOfAFinalCharacter(character: String) {
            let session = Session("ok \(character)\nnext\n", caret: 0)
            session.press("$")
            #expect(session.caret == 3)
        }

        @Test
        func jLandsOnACharacterStart() {
            // Column 2 on the second line is the second half of the emoji.
            let session = Session("abcdef\nx\(thumbsUp)yz\n", caret: 2)
            session.press("j")
            #expect(session.caret == 8)
            session.press("k")
            #expect(session.caret == 2)
        }

        @Test
        func eLandsOnTheStartOfAnEmojiWord() {
            let session = Session("ab \(thumbsUp) cd\n", caret: 0)
            session.press("ee")
            #expect(session.caret == 3)
        }

        // MARK: - Insert and append

        @Test(arguments: composedCharacters)
        func aAppendsAfterTheWholeCharacter(character: String) {
            let session = Session("x\(character)\n", caret: 1)
            session.press("a")
            #expect(session.engine.mode == .insert)
            #expect(session.caret == 1 + units(character))
            session.typeInTextView("!")
            #expect(session.text == "x\(character)!\n")
            session.escape()
            #expect(session.caret == 1 + units(character))
        }

        @Test(arguments: composedCharacters)
        func escapeFromInsertStepsBackOverTheWholeCharacter(character: String) {
            let session = Session("ab\(character)\n", caret: 2 + units(character))
            session.press("i")
            session.escape()
            #expect(session.engine.mode == .normal)
            #expect(session.caret == 2)
        }

        // MARK: - p

        @Test
        func pPastesAfterTheEmojiUnderTheCaret() {
            let session = Session("a\(thumbsUp)b\n", caret: 3)
            session.press("x")
            #expect(session.text == "a\(thumbsUp)\n")
            #expect(session.caret == 1)
            session.press("p")
            #expect(session.text == "a\(thumbsUp)b\n")
            #expect(session.caret == 3)
        }

        @Test
        func pLeavesTheCaretOnTheStartOfAPastedEmoji() {
            let session = Session("\(thumbsUp)ab\n", caret: 0)
            session.press("x")
            session.press("p")
            #expect(session.text == "a\(thumbsUp)b\n")
            #expect(session.caret == 1)
        }

        // MARK: - Operators with inclusive motions

        @Test
        func deDeletesThroughAnEmojiWord() {
            let session = Session("say \(thumbsUp) now\n", caret: 3)
            session.press("de")
            #expect(session.text == "say now\n")
            #expect(session.caret == 3)
        }

        @Test
        func deDeletesThroughALetterAndItsMark() {
            let session = Session("caf\(accented) ok\n", caret: 0)
            session.press("de")
            #expect(session.text == " ok\n")
            #expect(session.caret == 0)
        }

        @Test(arguments: composedCharacters)
        func dfDeletesThroughTheTargetCharacter(character: String) {
            let session = Session("go \(character) now\n", caret: 0)
            session.press("df\(character)")
            #expect(session.text == " now\n")
            #expect(session.caret == 0)
        }

        // MARK: - Operators with h and l

        @Test(arguments: composedCharacters + ["q"])
        func dlDeletesTheCharacterUnderTheCaret(character: String) {
            let session = Session("a\(character)b\n", caret: 1)
            session.press("dl")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
            #expect(session.engine.register.text == character)
        }

        @Test(arguments: composedCharacters + ["q"])
        func dlOnTheLastCharacterDeletesItAndStaysOnTheLine(character: String) {
            let session = Session("a\(character)\nnext\n", caret: 1)
            session.press("dl")
            #expect(session.text == "a\nnext\n")
            #expect(session.caret == 0)
        }

        @Test(arguments: composedCharacters + ["q"])
        func dhDeletesTheCharacterBeforeTheCaret(character: String) {
            let session = Session("a\(character)b\n", caret: 1 + units(character))
            session.press("dh")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
        }

        @Test
        func countedDlStopsAtTheLineEnd() {
            let session = Session("a\(thumbsUp)\(family)\nnext\n", caret: 1)
            session.press("5dl")
            #expect(session.text == "a\nnext\n")
            #expect(session.engine.mode == .normal)
        }

        @Test
        func clChangesTheWholeCharacter() {
            let session = Session("a\(family)b\n", caret: 1)
            session.press("cl")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
            #expect(session.engine.mode == .insert)
        }

        @Test
        func dDollarLeavesTheCaretOnTheNewLastCharacter() {
            let session = Session("ab\(thumbsUp)cd\nnext\n", caret: 4)
            session.press("d$")
            #expect(session.text == "ab\(thumbsUp)\nnext\n")
            #expect(session.caret == 2)
        }

        // MARK: - f, F, t, T

        @Test
        func fFindsAnEmojiAndRepeats() {
            // thumbs up at 3 and 10
            let session = Session("go \(thumbsUp) now \(thumbsUp)!\n", caret: 0)
            session.press("f\(thumbsUp)")
            #expect(session.caret == 3)
            session.press(";")
            #expect(session.caret == 10)
            session.press(",")
            #expect(session.caret == 3)
        }

        @Test
        func countedFFindsTheSecondEmoji() {
            let session = Session("go \(thumbsUp) now \(thumbsUp)!\n", caret: 0)
            session.press("2f\(thumbsUp)")
            #expect(session.caret == 10)
        }

        @Test
        func fFindsAFamilyAsOneCharacter() {
            let session = Session("a\(thumbsUp) \(family)b\n", caret: 0)
            session.press("f\(family)")
            #expect(session.caret == 4)
        }

        @Test
        func fWithAPrecomposedLetterFindsTheDecomposedOne() {
            let session = Session("caf\(accented)!\n", caret: 0)
            session.press("f\u{E9}")
            #expect(session.caret == 3)
        }

        @Test
        func tStopsOnTheCharacterBeforeAnEmoji() {
            let session = Session("go \(thumbsUp) now\n", caret: 0)
            session.press("t\(thumbsUp)")
            #expect(session.caret == 2)
        }

        @Test
        func tLandsOnAnEmojiBeforeTheTarget() {
            let session = Session("a\(thumbsUp)x\n", caret: 0)
            session.press("tx")
            #expect(session.caret == 1)
        }

        @Test
        func capitalFAndTFindAnEmojiBackward() {
            // thumbs up 3, space 5, w 8
            let find = Session("go \(thumbsUp) now\n", caret: 8)
            find.press("F\(thumbsUp)")
            #expect(find.caret == 3)

            let till = Session("go \(thumbsUp) now\n", caret: 8)
            till.press("T\(thumbsUp)")
            #expect(till.caret == 5)
        }

        // MARK: - R

        @Test(arguments: composedCharacters)
        func replaceModeOverwritesTheWholeCharacterAndBackspaceRestoresIt(character: String) {
            let session = Session("a\(character)b\n", caret: 1)
            session.press("R")
            session.press("x")
            #expect(session.text == "axb\n")
            #expect(session.caret == 2)
            session.backspace()
            #expect(session.text == "a\(character)b\n")
            #expect(session.caret == 1)
        }

        @Test(arguments: composedCharacters)
        func replaceModeTypesACharacterAndBackspaceRestoresTheLetter(character: String) {
            let session = Session("abc\n", caret: 1)
            session.press("R")
            session.press(character)
            #expect(session.text == "a\(character)c\n")
            #expect(session.caret == 1 + units(character))
            session.backspace()
            #expect(session.text == "abc\n")
            #expect(session.caret == 1)
        }

        @Test
        func replaceModeBackspaceRemovesAnAppendedEmoji() {
            let session = Session("ab\n", caret: 2)
            session.press("R")
            session.press(thumbsUp)
            #expect(session.text == "ab\(thumbsUp)\n")
            #expect(session.caret == 4)
            session.backspace()
            #expect(session.text == "ab\n")
            #expect(session.caret == 2)
        }

        @Test
        func escapeFromReplaceModeStepsBackOverAnEmoji() {
            let session = Session("abc\n", caret: 1)
            session.press("R")
            session.press(thumbsUp)
            session.escape()
            #expect(session.text == "a\(thumbsUp)c\n")
            #expect(session.caret == 1)
        }

        // MARK: - Visual

        @Test(arguments: composedCharacters)
        func vSelectsTheWholeCharacter(character: String) {
            let session = Session("a\(character)b\n", caret: 1)
            session.press("v")
            #expect(session.selection == NSRange(location: 1, length: units(character)))
        }

        @Test
        func visualLExtendsOverAnEmojiAndDeletes() {
            let session = Session("a\(thumbsUp)b\n", caret: 0)
            session.press("vl")
            #expect(session.selection == NSRange(location: 0, length: 3))
            session.press("l")
            #expect(session.selection == NSRange(location: 0, length: 4))
            session.press("d")
            #expect(session.text == "\n")
            #expect(session.engine.mode == .normal)
        }

        @Test
        func visualHExtendsBackOverAnEmoji() {
            let session = Session("a\(thumbsUp)b\n", caret: 3)
            session.press("vh")
            #expect(session.selection == NSRange(location: 1, length: 3))
            session.press("h")
            #expect(session.selection == NSRange(location: 0, length: 4))
        }

        @Test
        func visualDeleteOfAnEmoji() {
            let session = Session("a\(family)b\n", caret: 1)
            session.press("vd")
            #expect(session.text == "ab\n")
            #expect(session.caret == 1)
        }

        @Test
        func visualReplaceWritesOneCharacterPerCharacter() {
            let session = Session("a\(thumbsUp)b\n", caret: 0)
            session.press("vllr-")
            #expect(session.text == "---\n")
        }

        @Test
        func visualSwapKeepsTheEmojiWhole() {
            let session = Session("a\(thumbsUp)b\n", caret: 0)
            session.press("vlo")
            #expect(session.selection == NSRange(location: 0, length: 3))
            session.press("l")
            #expect(session.selection == NSRange(location: 1, length: 2))
        }

        // MARK: - The text view adapter

        private final class StubDelegate: TextViewDelegate {}

        private func makeTextView(_ string: String) -> TextView {
            let textView = TextView(
                string: string,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                textColor: .labelColor,
                lineHeightMultiplier: 1.0,
                wrapLines: false,
                isEditable: true,
                isSelectable: true,
                letterSpacing: 1.0,
                delegate: StubDelegate()
            )
            textView.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
            textView.layout()
            return textView
        }

        @Test
        func adapterCharacterRangeIsTheComposedSequence() {
            let textView = makeTextView("a\(thumbsUp)b")
            let adapter = VimTextBufferAdapter(textView: textView)
            withExtendedLifetime(textView) {
                #expect(adapter.characterRange(at: 2) == NSRange(location: 1, length: 2))
                #expect(adapter.characterRange(at: 3) == NSRange(location: 3, length: 1))
                #expect(adapter.characterRange(at: 4) == NSRange(location: 4, length: 0))
                #expect(adapter.characterRange(at: -1) == NSRange(location: 0, length: 0))
            }
        }

        @Test
        func adapterKeepsTheSelectionOnWholeCharacters() {
            let textView = makeTextView("a\(thumbsUp)b")
            let adapter = VimTextBufferAdapter(textView: textView)
            withExtendedLifetime(textView) {
                adapter.setSelectedRange(NSRange(location: 2, length: 0))
                #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
                adapter.setSelectedRange(NSRange(location: 2, length: 1))
                #expect(textView.selectedRange() == NSRange(location: 1, length: 2))
                adapter.setSelectedRange(NSRange(location: 0, length: 2))
                #expect(textView.selectedRange() == NSRange(location: 0, length: 3))
            }
        }

        @Test
        func engineOverTheTextViewStepsAndDeletesWholeEmoji() {
            let textView = makeTextView("INSERT INTO notes VALUES ('ok \(thumbsUp)')")
            let adapter = VimTextBufferAdapter(textView: textView)
            let engine = VimEngine(buffer: adapter)
            withExtendedLifetime(textView) {
                adapter.setSelectedRange(NSRange(location: 29, length: 0))
                _ = engine.process("l", shift: false)
                #expect(adapter.selectedRange().location == 30)
                _ = engine.process("l", shift: false)
                #expect(adapter.selectedRange().location == 32)
                _ = engine.process("h", shift: false)
                _ = engine.process("x", shift: false)
                #expect(textView.string == "INSERT INTO notes VALUES ('ok ')")
                #expect(adapter.selectedRange().location == 30)
            }
        }
    }
}
