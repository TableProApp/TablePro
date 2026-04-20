//
//  VimEngine.swift
//  TablePro
//
//  Core Vim state machine — processes character input and executes motions/operators
//

import Foundation
import os

/// Pending operator waiting for a motion
enum VimOperator {
    case delete
    case yank
    case change
}

/// Core Vim editing engine — deterministic state machine
@MainActor
final class VimEngine {
    private static let logger = Logger(subsystem: "com.TablePro", category: "VimEngine")

    // MARK: - State

    private(set) var mode: VimMode = .normal {
        didSet {
            if oldValue != mode {
                onModeChange?(mode)
            }
        }
    }

    /// Current cursor offset — in visual mode this is the moving end of the selection,
    /// in other modes it equals the caret position. Updated after every key press.
    private(set) var cursorOffset: Int = 0

    private var register = VimRegister()
    private var pendingOperator: VimOperator?
    private var countPrefix: Int = 0
    private var goalColumn: Int?
    private var pendingG: Bool = false

    /// Visual mode anchor offset
    private var visualAnchor: Int = 0

    private var buffer: VimTextBuffer?

    // MARK: - Callbacks

    /// Called when the mode changes
    var onModeChange: ((VimMode) -> Void)?

    /// Called when a command-line command is executed (e.g., ":w")
    var onCommand: ((String) -> Void)?

    // MARK: - Init

    init(buffer: VimTextBuffer) {
        self.buffer = buffer
    }

    // MARK: - Input Processing

    /// Process a character input. Returns `true` if the event was consumed.
    /// - Parameters:
    ///   - char: The character from NSEvent.characters
    ///   - shift: Whether shift was held
    /// - Returns: `true` if the key was consumed (event should be swallowed)
    func process(_ char: Character, shift: Bool) -> Bool {
        let consumed: Bool
        switch mode {
        case .normal:
            consumed = processNormal(char, shift: shift)
        case .insert:
            consumed = processInsert(char)
        case .visual:
            consumed = processVisual(char, shift: shift)
        case .commandLine(let commandBuffer):
            consumed = processCommandLine(char, buffer: commandBuffer)
        }
        // Keep cursorOffset in sync for non-visual modes
        if !mode.isVisual, let buffer {
            cursorOffset = buffer.selectedRange().location
        }
        return consumed
    }

    /// Redo the last undone change (called from interceptor for Ctrl+R)
    func redo() {
        buffer?.redo()
    }

    /// Invalidate the buffer's cached line count — call after external text changes
    func invalidateLineCache() {
        buffer?.invalidateLineCache()
    }

    /// Reset all pending state
    func reset() {
        pendingOperator = nil
        countPrefix = 0
        pendingG = false
        mode = .normal
    }

    // MARK: - Effective Count

    /// Returns the effective count (1 if no count was entered) and resets the prefix
    private func consumeCount() -> Int {
        let count = countPrefix > 0 ? countPrefix : 1
        countPrefix = 0
        return count
    }

    // MARK: - Normal Mode

    private func processNormal(_ char: Character, shift: Bool) -> Bool { // swiftlint:disable:this function_body_length
        guard let buffer else { return false }

        // Count prefix accumulation (1-9 start, 0-9 continue)
        if char.isNumber {
            let digit = char.wholeNumberValue ?? 0
            if countPrefix > 0 || digit > 0 {
                // Cap at 99999 to prevent arithmetic overflow from rapid key repeat
                guard countPrefix <= 99_999 else { return true }
                countPrefix = countPrefix * 10 + digit
                return true
            }
        }

        // Handle pending g
        if pendingG {
            pendingG = false
            if char == "g" {
                // gg — go to beginning
                let count = consumeCount()
                if count > 1 {
                    goToLine(count - 1, in: buffer)
                } else {
                    buffer.setSelectedRange(NSRange(location: 0, length: 0))
                }
                goalColumn = nil
                return true
            }
            countPrefix = 0
            return true // Consume unknown g-prefixed keys
        }

        switch char {
        // -- Motions --
        case "h":
            moveLeft(consumeCount(), in: buffer)
            return true
        case "j":
            moveDown(consumeCount(), in: buffer)
            return true
        case "k":
            moveUp(consumeCount(), in: buffer)
            return true
        case "l":
            moveRight(consumeCount(), in: buffer)
            return true
        case "w":
            let count = consumeCount()
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.wordForward(count, in: buffer) }, in: buffer)
            } else {
                wordForward(count, in: buffer)
            }
            goalColumn = nil
            return true
        case "b":
            let count = consumeCount()
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.wordBackward(count, in: buffer) }, in: buffer)
            } else {
                wordBackward(count, in: buffer)
            }
            goalColumn = nil
            return true
        case "e":
            let count = consumeCount()
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.wordEndMotion(count, in: buffer) }, inclusive: true, in: buffer)
            } else {
                wordEndMotion(count, in: buffer)
            }
            goalColumn = nil
            return true
        case "0":
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.moveToLineStart(in: buffer) }, in: buffer)
            } else {
                moveToLineStart(in: buffer)
            }
            goalColumn = nil
            return true
        case "$":
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: { self.moveToLineEnd(in: buffer) }, inclusive: true, in: buffer)
            } else {
                moveToLineEnd(in: buffer)
            }
            goalColumn = nil
            return true
        case "^", "_":
            if let op = pendingOperator {
                executeOperatorWithMotion(op, motion: {
                    let target = self.firstNonBlankOffset(from: buffer.selectedRange().location, in: buffer)
                    buffer.setSelectedRange(NSRange(location: target, length: 0))
                }, in: buffer)
            } else {
                let target = firstNonBlankOffset(from: buffer.selectedRange().location, in: buffer)
                buffer.setSelectedRange(NSRange(location: target, length: 0))
            }
            goalColumn = nil
            return true
        case "g":
            pendingG = true
            return true
        case "G":
            // G — go to end (or line N with count)
            let count = countPrefix
            countPrefix = 0
            if count > 0 {
                goToLine(count - 1, in: buffer)
            } else {
                let lastOffset = max(0, buffer.length - 1)
                let lineRange = buffer.lineRange(forOffset: lastOffset)
                buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            }
            goalColumn = nil
            return true

        // -- Insert mode entry --
        case "i":
            countPrefix = 0
            mode = .insert
            return true
        case "I":
            countPrefix = 0
            moveToLineStart(in: buffer)
            mode = .insert
            return true
        case "a":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            if pos < buffer.length {
                buffer.setSelectedRange(NSRange(location: pos + 1, length: 0))
            }
            mode = .insert
            return true
        case "A":
            countPrefix = 0
            moveToLineEnd(in: buffer)
            // Move one past the last character
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            let lineEnd = lineRange.location + lineRange.length
            // Position at end of line content (before newline if present)
            let targetEnd = lineEnd > lineRange.location && lineEnd <= buffer.length
                && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
            buffer.setSelectedRange(NSRange(location: targetEnd, length: 0))
            mode = .insert
            return true
        case "o":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            let lineEnd = lineRange.location + lineRange.length
            let lineEndsWithNewline = lineEnd > lineRange.location
                && buffer.character(at: lineEnd - 1) == 0x0A
            buffer.replaceCharacters(in: NSRange(location: lineEnd, length: 0), with: "\n")
            // When line has trailing \n: lineEnd is past the \n, inserted \n sits at lineEnd = blank line
            // When no trailing \n (last line): blank line starts at lineEnd + 1 (past inserted \n)
            let cursorPos = lineEndsWithNewline ? lineEnd : lineEnd + 1
            buffer.setSelectedRange(NSRange(location: cursorPos, length: 0))
            mode = .insert
            return true
        case "O":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: "\n")
            buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            mode = .insert
            return true

        // -- Visual mode --
        case "v":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            visualAnchor = pos
            cursorOffset = pos
            // Select the character under the cursor (Vim visual is inclusive)
            let initialLen = pos < buffer.length ? 1 : 0
            buffer.setSelectedRange(NSRange(location: pos, length: initialLen))
            mode = .visual(linewise: false)
            return true
        case "V":
            countPrefix = 0
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            visualAnchor = lineRange.location
            cursorOffset = pos
            buffer.setSelectedRange(lineRange)
            mode = .visual(linewise: true)
            return true

        // -- Operators --
        case "d":
            if pendingOperator == .delete {
                // dd — delete current line
                deleteLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            pendingOperator = .delete
            // Don't consume countPrefix — it's used by the second keystroke (dd, dw, etc.)
            return true
        case "y":
            if pendingOperator == .yank {
                // yy — yank current line
                yankLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            pendingOperator = .yank
            // Don't consume countPrefix — it's used by the second keystroke (yy, yw, etc.)
            return true
        case "c":
            if pendingOperator == .change {
                // cc — change current line
                changeLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            pendingOperator = .change
            // Don't consume countPrefix — it's used by the second keystroke (cc, cw, etc.)
            return true

        // -- Paste --
        case "p":
            countPrefix = 0
            paste(after: true, in: buffer)
            return true
        case "P":
            countPrefix = 0
            paste(after: false, in: buffer)
            return true

        // -- Search / Command line --
        case "/":
            countPrefix = 0
            mode = .commandLine(buffer: "/")
            return true
        case ":":
            countPrefix = 0
            mode = .commandLine(buffer: ":")
            return true

        // -- Undo --
        case "u":
            countPrefix = 0
            buffer.undo()
            return true

        // -- x: delete character under cursor --
        case "x":
            let count = consumeCount()
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            let lineEnd = lineRange.location + lineRange.length
            let contentEnd = lineEnd > lineRange.location
                && lineEnd <= buffer.length
                && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
            let deleteCount = min(count, max(0, contentEnd - pos))
            if deleteCount > 0 {
                let range = NSRange(location: pos, length: deleteCount)
                register.text = buffer.string(in: range)
                register.isLinewise = false
                register.syncToPasteboard()
                buffer.replaceCharacters(in: range, with: "")
            }
            return true

        default:
            // Escape
            if char == "\u{1B}" {
                pendingOperator = nil
                countPrefix = 0
                pendingG = false
                return true
            }
            countPrefix = 0
            pendingOperator = nil
            return true // Consume unknown keys in normal mode
        }
    }

    // MARK: - Insert Mode

    private func processInsert(_ char: Character) -> Bool {
        // Only Escape exits insert mode — all other keys pass through
        if char == "\u{1B}" {
            mode = .normal
            // Move cursor back one position (Vim convention)
            if let buffer, buffer.selectedRange().location > 0 {
                let pos = buffer.selectedRange().location
                let lineRange = buffer.lineRange(forOffset: pos)
                if pos > lineRange.location {
                    buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
                }
            }
            return true
        }
        return false // Pass through to text view
    }

    // MARK: - Visual Mode

    private func processVisual(_ char: Character, shift: Bool) -> Bool {
        guard let buffer else { return false }

        let isLinewise: Bool
        if case .visual(let lw) = mode { isLinewise = lw } else { isLinewise = false }

        // Handle pending g (gg motion in visual mode)
        if pendingG {
            pendingG = false
            if char == "g" {
                // gg — extend selection to beginning of buffer
                updateVisualSelection(cursorPos: 0, linewise: isLinewise, in: buffer)
                return true
            }
            return true // Consume unknown g-prefixed keys
        }

        switch char {
        case "\u{1B}": // Escape
            mode = .normal
            let pos = buffer.selectedRange().location
            buffer.setSelectedRange(NSRange(location: pos, length: 0))
            return true

        case "h", "j", "k", "l", "w", "b", "e", "0", "$", "G", "^", "_":
            // Motion — extend selection
            let cursorPos = visualCursorEnd(buffer: buffer)
            let newPos: Int
            switch char {
            case "h": newPos = max(0, cursorPos - 1)
            case "l": newPos = min(buffer.length, cursorPos + 1)
            case "j":
                let (line, col) = buffer.lineAndColumn(forOffset: cursorPos)
                let targetLine = min(buffer.lineCount - 1, line + 1)
                newPos = buffer.offset(forLine: targetLine, column: col)
            case "k":
                let (line, col) = buffer.lineAndColumn(forOffset: cursorPos)
                let targetLine = max(0, line - 1)
                newPos = buffer.offset(forLine: targetLine, column: col)
            case "w": newPos = buffer.wordBoundary(forward: true, from: cursorPos)
            case "b": newPos = buffer.wordBoundary(forward: false, from: cursorPos)
            case "e": newPos = buffer.wordEnd(from: cursorPos)
            case "0":
                let lineRange = buffer.lineRange(forOffset: cursorPos)
                newPos = lineRange.location
            case "$":
                let lineRange = buffer.lineRange(forOffset: cursorPos)
                let lineEnd = lineRange.location + lineRange.length
                newPos = lineEnd > lineRange.location
                    && lineEnd <= buffer.length
                    && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
            case "G":
                newPos = max(0, buffer.length - 1)
            case "^", "_":
                newPos = firstNonBlankOffset(from: cursorPos, in: buffer)
            default:
                newPos = cursorPos
            }
            updateVisualSelection(cursorPos: newPos, linewise: isLinewise, in: buffer)
            return true

        case "g":
            // gg in visual mode
            pendingG = true
            return true

        case "d", "x": // Delete selection
            let sel = buffer.selectedRange()
            if sel.length > 0 {
                register.text = buffer.string(in: sel)
                register.isLinewise = isLinewise
                register.syncToPasteboard()
                buffer.replaceCharacters(in: sel, with: "")
            }
            mode = .normal
            return true

        case "y": // Yank selection
            let sel = buffer.selectedRange()
            if sel.length > 0 {
                register.text = buffer.string(in: sel)
                register.isLinewise = isLinewise
                register.syncToPasteboard()
            }
            mode = .normal
            buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
            return true

        case "c": // Change selection
            let sel = buffer.selectedRange()
            if sel.length > 0 {
                register.text = buffer.string(in: sel)
                register.isLinewise = isLinewise
                register.syncToPasteboard()
                buffer.replaceCharacters(in: sel, with: "")
            }
            mode = .insert
            return true

        case "v":
            if isLinewise {
                mode = .visual(linewise: false)
                updateVisualSelection(cursorPos: visualCursorEnd(buffer: buffer), linewise: false, in: buffer)
            } else {
                mode = .normal
                let pos = buffer.selectedRange().location
                buffer.setSelectedRange(NSRange(location: pos, length: 0))
            }
            return true

        case "V":
            if isLinewise {
                mode = .normal
                let pos = buffer.selectedRange().location
                buffer.setSelectedRange(NSRange(location: pos, length: 0))
            } else {
                mode = .visual(linewise: true)
                updateVisualSelection(cursorPos: visualCursorEnd(buffer: buffer), linewise: true, in: buffer)
            }
            return true

        default:
            return true // Consume unknown keys in visual mode
        }
    }

    // MARK: - Command-Line Mode

    private func processCommandLine(_ char: Character, buffer commandBuffer: String) -> Bool {
        switch char {
        case "\u{1B}": // Escape — cancel
            mode = .normal
            return true
        case "\r", "\n": // Enter — execute
            let command = String(commandBuffer.dropFirst()) // Remove prefix (: or /)
            onCommand?(command)
            mode = .normal
            return true
        case "\u{7F}": // Backspace (DEL character)
            if (commandBuffer as NSString).length > 1 {
                mode = .commandLine(buffer: String(commandBuffer.dropLast()))
            } else {
                mode = .normal // Backspace on empty command exits
            }
            return true
        default:
            mode = .commandLine(buffer: commandBuffer + String(char))
            return true
        }
    }

    // MARK: - Visual Helpers

    private func visualCursorEnd(buffer: VimTextBuffer) -> Int {
        let sel = buffer.selectedRange()
        // The cursor is whichever end of the selection is not the anchor.
        // Selection is inclusive (length includes cursor char), so subtract 1 from the far end.
        if sel.location == visualAnchor {
            return sel.location + max(sel.length, 1) - 1
        }
        return sel.location
    }

    private func updateVisualSelection(cursorPos: Int, linewise: Bool, in buffer: VimTextBuffer) {
        cursorOffset = cursorPos
        let start = min(visualAnchor, cursorPos)
        let end = max(visualAnchor, cursorPos)

        if linewise {
            let startLineRange = buffer.lineRange(forOffset: start)
            let endLineRange = buffer.lineRange(forOffset: end)
            let lineStart = startLineRange.location
            let lineEnd = endLineRange.location + endLineRange.length
            buffer.setSelectedRange(NSRange(location: lineStart, length: lineEnd - lineStart))
        } else {
            // Inclusive: both anchor and cursor characters are part of the selection
            let length = end - start + (end < buffer.length ? 1 : 0)
            buffer.setSelectedRange(NSRange(location: start, length: length))
        }
    }

    // MARK: - Cursor Movement

    private func moveLeft(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let newPos = max(lineRange.location, pos - count)
        buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        goalColumn = nil
    }

    private func moveRight(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        // Don't go past end of line content (before newline)
        let contentEnd: Int
        if lineEnd > lineRange.location && lineEnd <= buffer.length && buffer.character(at: lineEnd - 1) == 0x0A {
            contentEnd = lineEnd - 1
        } else {
            contentEnd = lineEnd
        }
        let maxPos = max(lineRange.location, contentEnd - 1)
        let newPos = min(maxPos, pos + count)
        buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        goalColumn = nil
    }

    private func moveDown(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        if goalColumn == nil { goalColumn = col }
        let targetLine = min(buffer.lineCount - 1, line + count)
        let newPos = buffer.offset(forLine: targetLine, column: goalColumn ?? col)
        if let op = pendingOperator {
            // Operator + j/k: operate on lines
            let startLineRange = buffer.lineRange(forOffset: pos)
            let endLineRange = buffer.lineRange(forOffset: newPos)
            let rangeStart = min(startLineRange.location, endLineRange.location)
            let rangeEnd = max(
                startLineRange.location + startLineRange.length,
                endLineRange.location + endLineRange.length
            )
            let opRange = NSRange(location: rangeStart, length: rangeEnd - rangeStart)
            executeOperatorOnRange(op, range: opRange, linewise: true, in: buffer)
            pendingOperator = nil
        } else {
            buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        }
    }

    private func moveUp(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let (line, col) = buffer.lineAndColumn(forOffset: pos)
        if goalColumn == nil { goalColumn = col }
        let targetLine = max(0, line - count)
        let newPos = buffer.offset(forLine: targetLine, column: goalColumn ?? col)
        if let op = pendingOperator {
            let startLineRange = buffer.lineRange(forOffset: newPos)
            let endLineRange = buffer.lineRange(forOffset: pos)
            let rangeStart = min(startLineRange.location, endLineRange.location)
            let rangeEnd = max(
                startLineRange.location + startLineRange.length,
                endLineRange.location + endLineRange.length
            )
            let opRange = NSRange(location: rangeStart, length: rangeEnd - rangeStart)
            executeOperatorOnRange(op, range: opRange, linewise: true, in: buffer)
            pendingOperator = nil
        } else {
            buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        }
    }

    private func moveToLineStart(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
    }

    private func moveToLineEnd(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd: Int
        if lineEnd > lineRange.location && lineEnd <= buffer.length && buffer.character(at: lineEnd - 1) == 0x0A {
            contentEnd = lineEnd - 1
        } else {
            contentEnd = lineEnd
        }
        let finalPos = contentEnd > lineRange.location ? contentEnd - 1 : lineRange.location
        buffer.setSelectedRange(NSRange(location: finalPos, length: 0))
    }

    private func firstNonBlankOffset(from position: Int, in buffer: VimTextBuffer) -> Int {
        let lineRange = buffer.lineRange(forOffset: position)
        var target = lineRange.location
        let lineEnd = lineRange.location + lineRange.length
        while target < lineEnd {
            let ch = buffer.character(at: target)
            if ch != 0x20 && ch != 0x09 && ch != 0x0A { break }
            target += 1
        }
        if target >= lineEnd || buffer.character(at: target) == 0x0A {
            target = lineRange.location
        }
        return target
    }

    private func goToLine(_ line: Int, in buffer: VimTextBuffer) {
        let targetLine = min(max(0, line), buffer.lineCount - 1)
        let offset = buffer.offset(forLine: targetLine, column: 0)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
    }

    // MARK: - Word Motions

    private func wordForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = buffer.wordBoundary(forward: true, from: pos)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func wordBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = buffer.wordBoundary(forward: false, from: pos)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func wordEndMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = buffer.wordEnd(from: pos)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    // MARK: - Line Operations

    private func deleteLine(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let deleteRange = NSRange(location: startRange.location, length: endOffset - startRange.location)
        register.text = buffer.string(in: deleteRange)
        register.isLinewise = true
        register.syncToPasteboard()
        buffer.replaceCharacters(in: deleteRange, with: "")
        // Position cursor at start of next line (or current position if at end)
        let newPos = min(startRange.location, max(0, buffer.length - 1))
        if buffer.length > 0 {
            buffer.setSelectedRange(NSRange(location: newPos, length: 0))
        } else {
            buffer.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    private func yankLine(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let yankRange = NSRange(location: startRange.location, length: endOffset - startRange.location)
        register.text = buffer.string(in: yankRange)
        register.isLinewise = true
        register.syncToPasteboard()
    }

    private func changeLine(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        // For cc, delete line content but keep the newline, then enter insert mode
        let deleteEnd = endOffset > startRange.location && endOffset <= buffer.length
            && buffer.character(at: endOffset - 1) == 0x0A ? endOffset - 1 : endOffset
        let deleteRange = NSRange(location: startRange.location, length: deleteEnd - startRange.location)
        register.text = buffer.string(in: deleteRange)
        register.isLinewise = true
        register.syncToPasteboard()
        buffer.replaceCharacters(in: deleteRange, with: "")
        buffer.setSelectedRange(NSRange(location: startRange.location, length: 0))
        mode = .insert
    }

    // MARK: - Paste

    private func paste(after: Bool, in buffer: VimTextBuffer) {
        guard !register.text.isEmpty else { return }

        let pos = buffer.selectedRange().location

        if register.isLinewise {
            if after {
                let lineRange = buffer.lineRange(forOffset: pos)
                let insertPos = lineRange.location + lineRange.length
                var text = register.text
                let nsText = text as NSString
                if nsText.length == 0 || nsText.character(at: nsText.length - 1) != 0x0A {
                    text += "\n"
                }
                buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: text)
                buffer.setSelectedRange(NSRange(location: insertPos, length: 0))
            } else {
                let lineRange = buffer.lineRange(forOffset: pos)
                var text = register.text
                let nsText = text as NSString
                if nsText.length == 0 || nsText.character(at: nsText.length - 1) != 0x0A {
                    text += "\n"
                }
                buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: text)
                buffer.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            }
        } else {
            if after {
                let insertPos = min(pos + 1, buffer.length)
                buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: register.text)
                let newPos = insertPos + (register.text as NSString).length - 1
                buffer.setSelectedRange(NSRange(location: max(insertPos, newPos), length: 0))
            } else {
                buffer.replaceCharacters(in: NSRange(location: pos, length: 0), with: register.text)
                let newPos = pos + (register.text as NSString).length - 1
                buffer.setSelectedRange(NSRange(location: max(pos, newPos), length: 0))
            }
        }
    }

    // MARK: - Operator + Motion

    private func executeOperatorWithMotion(
        _ op: VimOperator,
        motion: () -> Void,
        inclusive: Bool = false,
        in buffer: VimTextBuffer
    ) {
        let startPos = buffer.selectedRange().location
        motion()
        let endPos = buffer.selectedRange().location

        let rangeStart = min(startPos, endPos)
        var rangeEnd = max(startPos, endPos)
        // Inclusive motions (like `e`) include the character at the end position
        if inclusive && rangeEnd < buffer.length {
            rangeEnd += 1
        }
        let range = NSRange(location: rangeStart, length: rangeEnd - rangeStart)

        executeOperatorOnRange(op, range: range, linewise: false, in: buffer)
        pendingOperator = nil
    }

    private func executeOperatorOnRange(_ op: VimOperator, range: NSRange, linewise: Bool, in buffer: VimTextBuffer) {
        guard range.length > 0 else { return }

        register.text = buffer.string(in: range)
        register.isLinewise = linewise
        register.syncToPasteboard()

        switch op {
        case .delete:
            buffer.replaceCharacters(in: range, with: "")
            let newPos = min(range.location, max(0, buffer.length - 1))
            buffer.setSelectedRange(NSRange(location: max(0, newPos), length: 0))
        case .yank:
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .change:
            buffer.replaceCharacters(in: range, with: "")
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
            mode = .insert
        }
    }
}
