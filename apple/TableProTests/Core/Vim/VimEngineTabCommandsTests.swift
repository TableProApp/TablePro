//
//  VimEngineTabCommandsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class VimEngineTabCommandsTests {
    private let buffer: VimTextBufferMock
    private let engine: VimEngine
    private var dispatched: [String] = []

    init() {
        buffer = VimTextBufferMock(text: "select 1;\nselect 2;\n", selectedRange: NSRange(location: 3, length: 0))
        engine = VimEngine(buffer: buffer)
        engine.onCommand = { [weak self] command in
            self?.dispatched.append(command)
        }
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    @Test(arguments: [
        ("gt", "tabnext"),
        ("3gt", "tabnext 3"),
        ("12gt", "tabnext 12"),
        ("gT", "tabprevious 1"),
        ("2gT", "tabprevious 2"),
    ])
    func dispatchesTheTabCommand(sequence: String, command: String) {
        keys(sequence)
        #expect(dispatched == [command])
        #expect(engine.mode == .normal)
    }

    @Test
    func gtLeavesTheBufferAlone() {
        keys("gt")
        #expect(buffer.text == "select 1;\nselect 2;\n")
        #expect(buffer.selectedRange() == NSRange(location: 3, length: 0))
        #expect(buffer.undoCallCount == 0)
    }

    @Test
    func countIsConsumedByGt() {
        keys("3gt")
        keys("x")
        #expect(buffer.text == "selct 1;\nselect 2;\n")
    }

    @Test
    func gtAfterAnOperatorCancelsBoth() {
        keys("dgt")
        #expect(dispatched.isEmpty)
        #expect(buffer.text == "select 1;\nselect 2;\n")
        keys("x")
        #expect(buffer.text == "selct 1;\nselect 2;\n")
    }

    @Test
    func gtInInsertModeGoesToTheTextView() {
        keys("i")
        let consumedG = engine.process("g", shift: false)
        let consumedT = engine.process("t", shift: false)
        #expect(!consumedG)
        #expect(!consumedT)
        #expect(dispatched.isEmpty)
        #expect(engine.mode == .insert)
    }

    @Test
    func hugeCountsBeforeGtAndGTStayBounded() {
        var selected: [Int] = []
        var offsets: [Int] = []
        var handler = VimCommandLineHandler()
        handler.tabCount = { 3 }
        handler.onSelectTab = { selected.append($0) }
        handler.onSelectAdjacentTab = { offsets.append($0) }
        engine.onCommand = { [weak self] command in
            self?.dispatched.append(command)
            handler.handle(command)
        }
        keys("99999999gt")
        keys("99999999gT")
        #expect(dispatched == ["tabnext 999999", "tabprevious 999999"])
        #expect(selected == [3])
        #expect(offsets == [0])
    }

    @Test
    func colonTabnextReachesTheHandler() {
        var selected: [Int] = []
        var handler = VimCommandLineHandler()
        handler.onSelectTab = { selected.append($0) }
        engine.onCommand = { handler.handle($0) }
        keys(":tabn 2")
        _ = engine.process("\r", shift: false)
        #expect(selected == [2])
    }
}

@MainActor
struct VimCommandLineHandlerTabTests {
    private final class Recorder {
        var tabNumbers: [Int] = []
        var offsets: [Int] = []
        var closed = 0
        var executed = 0
    }

    private func handle(_ command: String, tabs: Int? = nil) -> Recorder {
        let recorder = Recorder()
        var handler = VimCommandLineHandler()
        handler.tabCount = tabs.map { count in { count } }
        handler.onSelectTab = { recorder.tabNumbers.append($0) }
        handler.onSelectAdjacentTab = { recorder.offsets.append($0) }
        handler.onCloseTab = { recorder.closed += 1 }
        handler.onExecuteQuery = { recorder.executed += 1 }
        handler.handle(command)
        return recorder
    }

    @Test(arguments: ["tabn", "tabne", "tabnex", "tabnext", " tabnext "])
    func tabnextSelectsTheNextTab(command: String) {
        let recorder = handle(command)
        #expect(recorder.offsets == [1])
        #expect(recorder.tabNumbers.isEmpty)
    }

    @Test(arguments: ["tabn 4", "tabnext 4", "tabnext  4"])
    func tabnextWithANumberSelectsThatTab(command: String) {
        let recorder = handle(command)
        #expect(recorder.tabNumbers == [4])
        #expect(recorder.offsets.isEmpty)
    }

    @Test(arguments: [("tabnext +2", 2), ("tabn -3", -3)])
    func tabnextWithASignMovesRelative(command: String, offset: Int) {
        #expect(handle(command).offsets == [offset])
    }

    @Test(arguments: ["tabp 2", "tabpr 2", "tabprevious 2", "tabN 2", "tabNe 2", "tabNext 2"])
    func tabpreviousWithACountMovesBack(command: String) {
        let recorder = handle(command)
        #expect(recorder.offsets == [-2])
        #expect(recorder.tabNumbers.isEmpty)
    }

    @Test(arguments: ["tabp", "tabprevious", "tabN", "tabNext"])
    func tabpreviousSelectsThePreviousTab(command: String) {
        #expect(handle(command).offsets == [-1])
    }

    @Test(arguments: [
        "set", "tab", "tabnew", "tabnexts", "tabnext x", "tabnext 0", "tabp -1", "tabp +1", "tabnext 1 2", "TABN",
    ])
    func otherCommandsDoNothing(command: String) {
        let recorder = handle(command)
        #expect(recorder.tabNumbers.isEmpty)
        #expect(recorder.offsets.isEmpty)
        #expect(recorder.closed == 0)
        #expect(recorder.executed == 0)
    }

    @Test(arguments: [
        ("tabnext +9223372036854775807", 1),
        ("tabnext -9223372036854775808", -2),
        ("tabp 100000000000000000000", -1),
        ("tabN 999999", 0),
    ])
    func hugeRelativeCountsMoveLessThanOneLap(command: String, offset: Int) {
        #expect(handle(command, tabs: 3).offsets == [offset])
    }

    @Test(arguments: ["tabnext 99999999999999999999", "tabn 9223372036854775807", "tabnext 4"])
    func anAbsoluteCountPastTheLastTabSelectsTheLastTab(command: String) {
        #expect(handle(command, tabs: 3).tabNumbers == [3])
    }

    @Test
    func withoutATabCountACountStopsAtTheLimit() {
        #expect(handle("tabnext +9223372036854775807").offsets == [999_999])
        #expect(handle("tabp 99999999999999999999").offsets == [-999_999])
        #expect(handle("tabnext 99999999999999999999").tabNumbers == [999_999])
    }

    @Test
    func writeAndQuitStillWork() {
        #expect(handle("w").executed == 1)
        #expect(handle("q").closed == 1)
    }
}

@MainActor
struct QueryTabManagerOffsetTests {
    @Test(arguments: [Int.max, Int.min, Int.max - 1, Int.min + 1, -4, 7])
    func anyOffsetSelectsATabWithoutOverflow(offset: Int) {
        let manager = QueryTabManager()
        let tabs = (0..<3).map { QueryTab(title: "Query \($0)", query: "SELECT \($0)") }
        manager.tabs = tabs
        manager.selectedTabId = tabs[0].id
        #expect(manager.tabId(offsetBy: offset) == tabs[(offset % 3 + 3) % 3].id)
    }
}
