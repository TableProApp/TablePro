//
//  AccessibilityTests.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/17/25.
//

import Testing
import AppKit
@testable import CodeEditTextView

@MainActor
@Suite
struct AccessibilityTests {
    let textView: TextView
    let sampleText = "Line 1\nLine 2\nLine 3"

    init() {
        textView = TextView(string: sampleText)
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.updateFrameIfNeeded()
    }

    // MARK: - Basic Accessibility Properties

    @Test
    func isAccessibilityElement() {
        #expect(textView.isAccessibilityElement())
    }

    @Test
    func isAccessibilityEnabled() {
        #expect(textView.isAccessibilityEnabled())
    }

    @Test
    func accessibilityLabel() {
        #expect(textView.accessibilityLabel() == "Text Editor")
    }

    @Test
    func accessibilityRole() {
        #expect(textView.accessibilityRole() == .textArea)
    }

    @Test
    func accessibilityValue() {
        #expect(textView.accessibilityValue() as? String == sampleText)
    }

    @Test
    func setAccessibilityValue() {
        let newValue = "New content"
        textView.setAccessibilityValue(newValue)
        #expect(textView.string == newValue)
    }

    @Test
    func setAccessibilityValueInvalidType() {
        let originalString = textView.string
        textView.setAccessibilityValue(42)
        #expect(textView.string == originalString)
    }

    // MARK: - Character and String Access

    @Test
    func accessibilityNumberOfCharacters() {
        #expect(textView.accessibilityNumberOfCharacters() == sampleText.count)
    }

    @Test
    func accessibilityStringForRange() {
        let range = NSRange(location: 0, length: 6)
        let result = textView.accessibilityString(for: range)
        #expect(result == "Line 1")
    }

    @Test
    func accessibilityStringForInvalidRange() {
        let range = NSRange(location: 100, length: 5)
        let result = textView.accessibilityString(for: range)
        #expect(result == nil)
    }

    @Test
    func accessibilityRangeForCharacterIndex() {
        let range = textView.accessibilityRange(for: 0)
        #expect(range.location == 0)
        #expect(range.length == 1)
    }

    @Test
    func accessibilityRangeForInvalidIndex() {
        let range = textView.accessibilityRange(for: 1000)
        #expect(range == .notFound)
    }

    // MARK: - Selection Tests

    @Test
    func accessibilitySelectedTextNoSelections() {
        textView.selectionManager.setSelectedRanges([])
        #expect(textView.accessibilitySelectedText() == nil)
    }

    @Test
    func accessibilitySelectedTextEmpty() {
        textView.selectionManager.setSelectedRange(.zero)
        #expect(textView.accessibilitySelectedText() == "")
    }

    @Test
    func accessibilitySelectedText() {
        let range = NSRange(location: 0, length: 6)
        textView.selectionManager.setSelectedRange(range)
        #expect(textView.accessibilitySelectedText() == "Line 1")
    }

    @Test
    func accessibilitySelectedTextRange() {
        let range = NSRange(location: 2, length: 4)
        textView.selectionManager.setSelectedRange(range)
        let selectedRange = textView.accessibilitySelectedTextRange()
        #expect(selectedRange.location == 2)
        #expect(selectedRange.length == 4)
    }

    @Test
    func accessibilitySelectedTextRangeEmpty() {
        textView.selectionManager.setSelectedRange(.zero)
        let selectedRange = textView.accessibilitySelectedTextRange()
        #expect(selectedRange == .zero)
    }

    @Test
    func setAccessibilitySelectedTextRange() {
        let range = NSRange(location: 7, length: 6)
        textView.setAccessibilitySelectedTextRange(range)
        #expect(textView.accessibilitySelectedTextRange() == range)
    }

    @Test
    func accessibilitySelectedTextRanges() {
        let ranges = [
            NSRange(location: 0, length: 4),
            NSRange(location: 7, length: 6)
        ]
        textView.selectionManager.setSelectedRanges(ranges)
        let selectedRanges = textView.accessibilitySelectedTextRanges()?.compactMap { $0 as? NSRange }
        #expect(selectedRanges?.count == 2)
        #expect(selectedRanges?.contains(ranges[0]) == true)
        #expect(selectedRanges?.contains(ranges[1]) == true)
    }

    @Test
    func setAccessibilitySelectedTextRanges() {
        let ranges = [
            NSRange(location: 0, length: 4) as NSValue,
            NSRange(location: 7, length: 6) as NSValue
        ]
        textView.setAccessibilitySelectedTextRanges(ranges)
        let selectedRanges = textView.accessibilitySelectedTextRanges()
        #expect(selectedRanges?.count == 2)
    }

    @Test
    func setAccessibilitySelectedTextRangesNil() {
        textView.setAccessibilitySelectedTextRanges(nil)
        let selectedRanges = textView.accessibilitySelectedTextRanges()
        #expect(selectedRanges?.isEmpty == true)
    }

    // MARK: - Line Navigation Tests

    @Test
    func accessibilityLineForIndex() {
        let lineIndex = textView.accessibilityLine(for: 0)
        #expect(lineIndex == 0)
    }

    @Test
    func accessibilityLineForIndexSecondLine() {
        let lineIndex = textView.accessibilityLine(for: 7)
        #expect(lineIndex == 1)
    }

    @Test
    func accessibilityLineForEndOfDocument() {
        let lineIndex = textView.accessibilityLine(for: textView.documentRange.max)
        #expect(lineIndex == 2)
    }

    @Test
    func accessibilityLineForInvalidIndex() {
        let lineIndex = textView.accessibilityLine(for: 1000)
        #expect(lineIndex == -1)
    }

    @Test
    func accessibilityRangeForLine() {
        let range = textView.accessibilityRange(forLine: 0)
        #expect(range.location == 0)
        #expect(range.length == 7)
    }

    @Test
    func accessibilityRangeForLineSecondLine() {
        let range = textView.accessibilityRange(forLine: 1)
        #expect(range.location == 7)
        #expect(range.length == 7)
    }

    @Test
    func accessibilityRangeForInvalidLine() {
        let range = textView.accessibilityRange(forLine: 100)
        #expect(range == .zero)
    }

    @Test
    func accessibilityRangeForNegativeLine() {
        let range = textView.accessibilityRange(forLine: -1)
        #expect(range == .zero)
    }

    @Test
    func accessibilityInsertionPointLineNumber() {
        textView.selectionManager.setSelectedRange(NSRange(location: 7, length: 0))
        let lineNumber = textView.accessibilityInsertionPointLineNumber()
        #expect(lineNumber == 1)
    }

    @Test
    func accessibilityInsertionPointLineNumberEmptySelection() {
        textView.selectionManager.setSelectedRange(.zero)
        let lineNumber = textView.accessibilityInsertionPointLineNumber()
        #expect(lineNumber == 0)
    }

    @Test
    func accessibilityInsertionPointLineNumberNoSelection() {
        textView.selectionManager.setSelectedRanges([])
        let lineNumber = textView.accessibilityInsertionPointLineNumber()
        #expect(lineNumber == -1)
    }

    // MARK: - Visible Range Tests

    @Test
    func accessibilityVisibleCharacterRange() {
        let visibleRange = textView.accessibilityVisibleCharacterRange()
        #expect(visibleRange != .notFound)
    }

    @Test
    func accessibilityVisibleCharacterRangeNoVisibleText() {
        let emptyTextView = TextView(string: "")
        let visibleRange = emptyTextView.accessibilityVisibleCharacterRange()
        #expect(visibleRange == .zero)
    }

    // MARK: - Point and Frame Tests

    @Test
    func accessibilityRangeForPoint() {
        let point = NSPoint(x: 10, y: 10)
        let range = textView.accessibilityRange(for: point)
        #expect(range.length == 0)
    }

    @Test
    func accessibilityRangeForInvalidPoint() {
        let point = NSPoint(x: -100, y: -100)
        let range = textView.accessibilityRange(for: point)
        #expect(range == .zero)
    }

    @Test
    func accessibilityFrameForRange() {
        let range = NSRange(location: 0, length: 6)
        let frame = textView.accessibilityFrame(for: range)
        #expect(frame.size.width > 0)
        #expect(frame.size.height > 0)
    }

    @Test
    func accessibilityFrameForEmptyRange() {
        let range = NSRange(location: 0, length: 0)
        let frame = textView.accessibilityFrame(for: range)
        #expect(frame.size.width >= 0)
        #expect(frame.size.height >= 0)
    }

    @Test
    func isAccessibilityFocusedWhenNotFirstResponder() {
        textView.window?.makeFirstResponder(nil)
        #expect(!textView.isAccessibilityFocused())
    }
}
