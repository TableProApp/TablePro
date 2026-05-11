//
//  VimEngineFindCharTests.swift
//  TableProTests
//
//  Specification tests for f / F / t / T character search motions and ; / , repetition.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineFindCharTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        // "hello world foo bar\nsecond line\n"
        //  0123456789012345678901234567890
        buffer = VimTextBufferMock(text: "hello world foo bar\nsecond line\n")
        engine = VimEngine(buffer: buffer)
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - f: Find Forward (Inclusive)

    func testFMovesToNextOccurrenceOnLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("fo")
        XCTAssertEqual(pos, 4, "fo from offset 0 should land on the 'o' in 'hello' (offset 4)")
    }

    func testFFromMidLineFindsNextOccurrence() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("fo")
        XCTAssertEqual(pos, 7, "fo from offset 5 should find the next 'o' at offset 7")
    }

    func testFNotFoundStaysPut() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("fz")
        XCTAssertEqual(pos, 0, "f for a missing char should leave the cursor unchanged")
    }

    func testFDoesNotCrossLineBoundary() {
        // 's' from 'second' is on line 1 — f from line 0 must not jump there.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("fs")
        XCTAssertEqual(pos, 0, "f must search only within the current line")
    }

    func testFWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2fo")
        XCTAssertEqual(pos, 7, "2fo should land on the second 'o' (offset 7 in 'world')")
    }

    func testFThirdOccurrence() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3fo")
        XCTAssertEqual(pos, 13, "3fo should land on the 'o' in 'foo' (offset 13)")
    }

    func testFCountLargerThanAvailableStaysPut() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("99fo")
        XCTAssertEqual(pos, 0, "f with count beyond available matches is a no-op")
    }

    // MARK: - F: Find Backward (Inclusive)

    func testCapitalFMovesToPreviousOccurrence() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        key("F", shift: true)
        key("o")
        XCTAssertEqual(pos, 7, "Fo from offset 10 should find the previous 'o' at offset 7")
    }

    func testCapitalFNotFoundStaysPut() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        key("F", shift: true)
        key("z")
        XCTAssertEqual(pos, 10)
    }

    func testCapitalFDoesNotCrossLineBoundary() {
        // Start on line 1, look for 'h' (which is on line 0) — should not jump.
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        key("F", shift: true)
        key("h")
        XCTAssertEqual(pos, 20)
    }

    func testCapitalFWithCount() {
        buffer.setSelectedRange(NSRange(location: 18, length: 0))
        keys("2")
        key("F", shift: true)
        key("o")
        XCTAssertEqual(pos, 13, "2Fo from offset 18 should find the second prior 'o' at offset 13")
    }

    // MARK: - t: Till Forward (Stop Before)

    func testTLandsOneCharBeforeMatch() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("to")
        XCTAssertEqual(pos, 3, "to from offset 0 should land at offset 3 (one before the 'o' at 4)")
    }

    func testTAlreadyAdjacentSkipsToNext() {
        // Cursor at 3 ('l' just before 'o' at 4). t shouldn't be a no-op — it should
        // find the NEXT 'o' and land one char before it.
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("to")
        XCTAssertEqual(pos, 6, "t when already adjacent should skip to the next match")
    }

    func testTNotFoundStaysPut() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("tz")
        XCTAssertEqual(pos, 0)
    }

    func testTDoesNotCrossLineBoundary() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ts")
        XCTAssertEqual(pos, 0)
    }

    func testTWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2to")
        XCTAssertEqual(pos, 6, "2to should land one char before the second 'o' (offset 6)")
    }

    // MARK: - T: Till Backward (Stop After)

    func testCapitalTLandsOneCharAfterMatch() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        key("T", shift: true)
        key("o")
        XCTAssertEqual(pos, 8, "To from offset 10 should land at offset 8 (one after 'o' at 7)")
    }

    func testCapitalTNotFoundStaysPut() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        key("T", shift: true)
        key("z")
        XCTAssertEqual(pos, 10)
    }

    func testCapitalTWithCount() {
        // From offset 18 ('r' in 'bar'), prior 'o' occurrences are at 14, 13, 7, 4.
        // 2T finds the 2nd backward (offset 13), till lands one after → offset 14.
        buffer.setSelectedRange(NSRange(location: 18, length: 0))
        keys("2")
        key("T", shift: true)
        key("o")
        XCTAssertEqual(pos, 14, "2To from offset 18 should land one after the second prior 'o' (offset 14)")
    }

    // MARK: - ; (Repeat Last f/F/t/T)

    func testSemicolonRepeatsForwardFind() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("fo")     // → 4
        keys(";")      // → 7
        XCTAssertEqual(pos, 7)
        keys(";")      // → 13 (in 'foo')
        XCTAssertEqual(pos, 13)
    }

    func testSemicolonRepeatsBackwardFind() {
        buffer.setSelectedRange(NSRange(location: 18, length: 0))
        key("F", shift: true)
        key("o")
        XCTAssertEqual(pos, 14, "Fo from 18 should find 'o' at 14 ('foo')")
        keys(";")
        XCTAssertEqual(pos, 13, "; should repeat F backward to next 'o' at 13")
    }

    func testSemicolonRepeatsTill() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("to")
        XCTAssertEqual(pos, 3)
        keys(";")
        XCTAssertEqual(pos, 6, "; should repeat t, landing before the next 'o'")
    }

    func testSemicolonWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("fo")
        XCTAssertEqual(pos, 4)
        keys("2;")
        XCTAssertEqual(pos, 13, "2; should repeat fo twice forward")
    }

    // MARK: - , (Reverse Last f/F/t/T)

    func testCommaReversesForwardFind() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("fo")  // forward → 4
        keys("fo")  // → 7
        keys(",")   // reverse → 4
        XCTAssertEqual(pos, 4)
    }

    func testCommaReversesBackwardFind() {
        // From offset 18 ('r'), Fo finds 'o' at 14. There is no 'o' after offset 14 on
        // this line, so reverse-search (forward) is a no-op and the cursor stays at 14.
        buffer.setSelectedRange(NSRange(location: 18, length: 0))
        key("F", shift: true)
        key("o")
        XCTAssertEqual(pos, 14)
        keys(",")
        XCTAssertEqual(pos, 14, ", reverse from 14 has no later 'o' on the line so cursor stays")
    }

    func testCommaWithCount() {
        // From offset 13 ('o'), fo lands at 14. 2, reverses direction (backward) twice:
        // 14 → 13 → 7. Final cursor at 7.
        buffer.setSelectedRange(NSRange(location: 13, length: 0))
        keys("fo")
        keys("2,")
        XCTAssertEqual(pos, 7, "2, after fo should walk backward through two 'o' occurrences")
    }

    // MARK: - Combined with Operators

    func testDeleteUntilCharacter() {
        // dfo from 0 should delete "hello" (inclusive of 'o' at offset 4)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dfo")
        XCTAssertEqual(buffer.text, " world foo bar\nsecond line\n",
            "dfo should delete from cursor through and including the matched 'o'")
    }

    func testDeleteTillCharacter() {
        // dto from 0 should delete "hell" (up to but not including 'o' at offset 4)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dto")
        XCTAssertEqual(buffer.text, "o world foo bar\nsecond line\n",
            "dto should delete up to (but not including) the matched 'o'")
    }

    func testChangeUntilCharacter() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("cfo")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, " world foo bar\nsecond line\n")
    }

    func testYankUntilCharacter() {
        // yfo should yank "hello" without modifying buffer
        let original = buffer.text
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yfo")
        XCTAssertEqual(buffer.text, original)
    }

    // MARK: - Pending Find Cancellation

    func testFThenEscapeCancels() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("f")
        _ = engine.process("\u{1B}", shift: false)
        // Next key should be treated as a normal command, not the find-char target.
        keys("l")
        XCTAssertEqual(pos, 1, "After Escape during f, next key should run as normal command")
    }
}
