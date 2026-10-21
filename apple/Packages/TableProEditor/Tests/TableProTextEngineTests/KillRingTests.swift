import AppKit
@testable import TableProTextEngine
import Testing

// The view-level cases use `KillRing.shared`, the ring the text views use. Each starts with a kill of its own, so an
// entry another test left behind never reaches a yank here.
@MainActor
struct KillRingTests {
    private func continuation(_ count: Int) -> KillRing.Continuation {
        KillRing.Continuation(owner: ObjectIdentifier(KillRing.self), selectionChangeCount: count, length: 0)
    }

    private func selectedRanges(_ view: TextView) -> [NSRange] {
        view.selectionManager.textSelections.map { $0.range }
    }

    private func textView(_ string: String, caret: Int) -> TextView {
        let view = TextView(string: string)
        view.selectionManager.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    // MARK: - The ring

    @Test("A kill that continues the last one joins it, forward after and backward before")
    func continuingKillsJoin() {
        let ring = KillRing(5)
        ring.kill(["a"], direction: .forward, before: nil, after: continuation(1))
        ring.kill(["b"], direction: .forward, before: continuation(1), after: continuation(2))
        ring.kill(["c"], direction: .backward, before: continuation(2), after: continuation(3))
        #expect(ring.entries == [["cab"]])

        ring.kill(["d"], direction: .forward, before: continuation(9), after: continuation(10))
        #expect(ring.entries == [["d"], ["cab"]])
    }

    @Test("A yank in between starts a new entry")
    func yankBreaksTheChain() {
        let ring = KillRing(5)
        ring.kill(["a"], direction: .forward, before: nil, after: continuation(1))
        ring.didYank(KillRing.Yank(continuation: continuation(1), ranges: []))
        ring.kill(["b"], direction: .forward, before: continuation(1), after: continuation(2))
        #expect(ring.entries == [["b"], ["a"]])
    }

    @Test("Rotating walks to older entries and wraps to the newest; a new kill resets the pointer")
    func rotateWalksOlderEntries() {
        let ring = KillRing(5)
        for (index, word) in ["one", "two", "three"].enumerated() {
            ring.kill([word], direction: .forward, before: nil, after: continuation(index))
        }
        #expect(ring.yank() == ["three"])
        #expect(ring.rotate() == ["two"])
        #expect(ring.yank() == ["two"])
        #expect(ring.rotate() == ["one"])
        #expect(ring.rotate() == ["three"])

        _ = ring.rotate()
        ring.kill(["four"], direction: .forward, before: nil, after: continuation(9))
        #expect(ring.yank() == ["four"])
    }

    @Test("The ring keeps its capacity by dropping the oldest entry")
    func capacityDropsTheOldest() {
        let ring = KillRing(2)
        for (index, word) in ["one", "two", "three"].enumerated() {
            ring.kill([word], direction: .forward, before: nil, after: continuation(index))
        }
        #expect(ring.entries == [["three"], ["two"]])
    }

    @Test("An empty ring yanks nothing")
    func emptyRingYanksNothing() {
        let ring = KillRing(3)
        #expect(ring.yank().isEmpty)
        #expect(ring.rotate().isEmpty)
    }

    @Test("Without NSTextKillRingSize the ring holds more than one entry, so yank-pop has something to cycle")
    func defaultCapacityAllowsYankPop() {
        #expect(KillRing.defaultCapacity > 1)
    }

    // MARK: - What fills it

    @Test("Ctrl+K, Backspace, Ctrl+Y yanks the kill, not the character Backspace removed (#2539)")
    func backspaceLeavesTheRingAlone() {
        let view = textView("SELECT 1 FROM t", caret: 9)
        view.deleteToEndOfParagraph(nil)
        #expect(view.string == "SELECT 1 ")
        view.deleteBackward(nil)
        view.yank(nil)
        #expect(view.string == "SELECT 1FROM t")
    }

    @Test("Deletions that are not kills leave the ring alone")
    func plainDeletionsLeaveTheRingAlone() {
        let view = textView("keep aaa bbb ccc", caret: 0)
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 4))
        view.killSelection(nil)
        view.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        view.deleteForward(nil)
        view.deleteWordForward(nil)
        view.deleteWordBackward(nil)
        view.delete(view)
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        view.yank(nil)
        #expect(view.string.hasPrefix("keep"))
    }

    @Test("Kills in a row join into one entry")
    func killsInARowJoin() {
        let view = textView("one\ntwo\nthree", caret: 0)
        view.deleteToEndOfParagraph(nil)
        view.deleteToEndOfParagraph(nil)
        view.deleteToEndOfParagraph(nil)
        #expect(view.string == "\nthree")
        view.yank(nil)
        #expect(view.string == "one\ntwo\nthree")
    }

    @Test("A move between two kills starts a new entry, even back to the same place")
    func moveBetweenKillsStartsANewEntry() {
        let view = textView("aaa\nbbb", caret: 0)
        view.deleteToEndOfParagraph(nil)
        view.moveRight(nil)
        view.moveLeft(nil)
        view.deleteToEndOfParagraph(nil)
        #expect(view.string == "bbb")
        view.yank(nil)
        #expect(view.string == "\nbbb")
    }

    @Test("Backward kills in a row put the newer text in front")
    func backwardKillsPrepend() {
        let view = textView("foo bar baz", caret: 11)
        view.killWordBackward(nil)
        view.killWordBackward(nil)
        #expect(view.string == "foo ")
        view.yank(nil)
        #expect(view.string == "foo bar baz")
    }

    @Test("Kills in two views never join")
    func killsInTwoViewsNeverJoin() {
        let first = textView("AAA\n", caret: 0)
        let second = textView("BBB\n", caret: 0)
        first.deleteToEndOfParagraph(nil)
        second.deleteToEndOfParagraph(nil)
        second.yank(nil)
        #expect(second.string == "BBB\n")
    }

    @Test("A line kill at a line end takes the line ending", arguments: ["\n", "\r\n"])
    func killAtLineEndJoinsLines(_ lineEnding: String) {
        let view = textView("aaa\(lineEnding)bbb", caret: 3)
        view.deleteToEndOfParagraph(nil)
        #expect(view.string == "aaabbb")
        view.yank(nil)
        #expect(view.string == "aaa\(lineEnding)bbb")
    }

    @Test("A kill with a selection kills the selection")
    func killWithSelectionKillsIt() {
        let view = textView("aaa bbb", caret: 0)
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 3))
        view.deleteToEndOfParagraph(nil)
        #expect(view.string == " bbb")
        view.yank(nil)
        #expect(view.string == "aaa bbb")
    }

    @Test("Killing a word forward fills the ring and joins the next kill")
    func killWordForwardJoins() {
        let view = textView("foo bar baz", caret: 0)
        view.killWordForward(nil)
        view.killWordForward(nil)
        #expect(view.string == " baz")
        view.yank(nil)
        #expect(view.string == "foo bar baz")
    }

    @Test("Copying the selection to the ring leaves the text and the selection as they were")
    func copySelectionToKillRing() {
        let view = textView("abc def", caret: 0)
        view.selectionManager.setSelectedRange(NSRange(location: 4, length: 3))
        view.copySelectionToKillRing(nil)
        #expect(view.string == "abc def")
        #expect(selectedRanges(view) == [NSRange(location: 4, length: 3)])
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        view.yank(nil)
        #expect(view.string == "defabc def")
    }

    @Test("Killing an empty selection changes nothing")
    func killEmptySelection() {
        let view = textView("abc", caret: 1)
        view.killSelection(nil)
        #expect(view.string == "abc")
    }

    // MARK: - Yank

    @Test("Each cursor yanks its own string from a multi-cursor kill; one cursor gets them all")
    func multiCursorYank() {
        let view = TextView(string: "Hello World")
        view.selectionManager.setSelectedRanges([NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)])
        view.killSelection(nil)
        #expect(view.string == "elo World")

        view.yank(nil)
        #expect(view.string == "Hello World")
        view.selectionManager.setSelectedRanges([NSRange(location: 0, length: 0)])
        view.yank(nil)
        #expect(view.string == "H\nlHello World")
    }

    @Test("One undo reverses a kill at several cursors")
    func multiCursorKillUndoesInOneStep() {
        let view = TextView(string: "Hello World")
        view.selectionManager.setSelectedRanges([NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)])
        view.killSelection(nil)
        #expect(view.string == "ello orld")
        view.undoManager?.undo()
        #expect(view.string == "Hello World")
    }

    @Test("A single kill yanks at every cursor")
    func singleKillYanksAtEveryCursor() {
        let view = textView("X ab", caret: 0)
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 1))
        view.killSelection(nil)
        view.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 2, length: 0)])
        view.yank(nil)
        #expect(view.string == " XaXb")
    }

    @Test("Yank-pop swaps the yanked text for older entries and leaves the caret after it")
    func yankPopCyclesOlderEntries() {
        let source = textView("one two three", caret: 0)
        for _ in 0..<3 {
            source.killWordForward(nil)
            source.moveRight(nil)
        }
        let view = textView("", caret: 0)
        view.yank(nil)
        #expect(view.string == "three")
        view.yankPop(nil)
        #expect(view.string == "two")
        view.yankPop(nil)
        #expect(view.string == "one")
        #expect(selectedRanges(view) == [NSRange(location: 3, length: 0)])
    }

    @Test("Yank-pop does nothing unless the last command was a yank")
    func yankPopNeedsAYank() {
        let view = textView("abc", caret: 0)
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 1))
        view.killSelection(nil)
        view.yank(nil)
        view.moveLeft(nil)
        view.yankPop(nil)
        #expect(view.string == "abc")
    }

    @Test("Yank-and-select selects the yank, and the next one swaps in the next older entry")
    func yankAndSelect() {
        let source = textView("one two", caret: 0)
        source.killWordForward(nil)
        source.moveRight(nil)
        source.killWordForward(nil)
        let view = textView("", caret: 0)
        view.yankAndSelect(nil)
        #expect(view.string == "two")
        #expect(selectedRanges(view) == [NSRange(location: 0, length: 3)])
        view.yankAndSelect(nil)
        #expect(view.string == "one")
        #expect(selectedRanges(view) == [NSRange(location: 0, length: 3)])
    }
}
