import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

// The controller runs auto-indent, bracket pairs and indentation-wide deletes on every typed edit. Kills, yanks,
// transpositions and Ctrl+O have to move exactly the text they name past those filters.
@MainActor
struct KillYankTypingFilterTests {
    // The controller is the text view's weak delegate and runs the filters, so each test holds it.
    private func editor(_ string: String, selecting range: NSRange) -> TextViewController {
        let controller = Mock.loadedTextViewController(string: string)
        controller.textView.selectionManager.setSelectedRange(range)
        return controller
    }

    private func selection(_ textView: TextView) -> [NSRange] {
        textView.selectionManager.textSelections.map { $0.range }
    }

    @Test("Ctrl+O on an indented line adds a bare line break and leaves the caret where it was")
    func controlOOnIndentedLine() {
        let controller = editor("    SELECT", selecting: NSRange(location: 10, length: 0))
        let textView: TextView = controller.textView
        textView.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        textView.doCommand(by: #selector(NSResponder.moveBackward(_:)))
        #expect(textView.string == "    SELECT\n")
        #expect(selection(textView) == [NSRange(location: 10, length: 0)])
        withExtendedLifetime(controller) {}
    }

    @Test("Killing one leading space kills that space only, and Ctrl+Y puts it back")
    func killRegionInIndentation() {
        let controller = editor("    SELECT", selecting: NSRange(location: 0, length: 1))
        let textView: TextView = controller.textView
        textView.killSelection(nil)
        #expect(textView.string == "   SELECT")
        textView.yank(nil)
        #expect(textView.string == "    SELECT")
        withExtendedLifetime(controller) {}
    }

    @Test("A yanked open bracket arrives alone, and yank-pop swaps in exactly the older entry")
    func yankBracketVerbatim() {
        let controller = editor("( abc", selecting: NSRange(location: 0, length: 1))
        let textView: TextView = controller.textView
        textView.killSelection(nil)
        textView.selectionManager.setSelectedRange(NSRange(location: 1, length: 3))
        textView.killSelection(nil)
        #expect(textView.string == " ")

        textView.yank(nil)
        #expect(textView.string == " abc")
        textView.yankPop(nil)
        #expect(textView.string == " (")
        #expect(selection(textView) == [NSRange(location: 2, length: 0)])
        withExtendedLifetime(controller) {}
    }

    @Test("Ctrl+K before a closing bracket kills to the line end and nothing past it")
    func killLineBeforeCloseBracket() {
        let controller = editor("f(x)\nnext", selecting: NSRange(location: 2, length: 0))
        let textView: TextView = controller.textView
        textView.deleteToEndOfParagraph(nil)
        #expect(textView.string == "f(\nnext")
        withExtendedLifetime(controller) {}
    }

    @Test("Ctrl+T across a line break swaps the two characters and adds no indentation")
    func transposeAcrossLineBreak() {
        let controller = editor("    a\n    b", selecting: NSRange(location: 6, length: 0))
        let textView: TextView = controller.textView
        textView.doCommand(by: #selector(NSResponder.transpose(_:)))
        #expect(textView.string == "    a \n   b")
        withExtendedLifetime(controller) {}
    }
}
