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
    case lowercase
    case uppercase
    case toggleCase
    case indent
    case outdent
}

/// f/F/t/T pending state — captures whether the next char is a forward/backward find,
/// and whether it lands on the match (`f`) or just before/after it (`t`).
struct VimFindCharRequest {
    let forward: Bool
    let till: Bool
}

/// The last executed f/F/t/T — used by `;` (repeat) and `,` (reverse).
struct VimLastFindChar {
    let char: Character
    let forward: Bool
    let till: Bool
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
    private var operatorCount: Int = 0
    private var goalColumn: Int?
    private var pendingG: Bool = false
    private var pendingFindChar: VimFindCharRequest?
    private var pendingReplaceChar: Bool = false
    private var lastFindChar: VimLastFindChar?

    /// Visual mode anchor offset
    private var visualAnchor: Int = 0

    /// Cursor offset when insert mode was last exited — used by `gi`
    private var lastInsertOffset: Int?

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
        case .replace:
            consumed = processReplace(char)
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
        operatorCount = 0
        pendingG = false
        mode = .normal
    }

    // MARK: - Effective Count

    /// Returns the effective count and resets both prefixes.
    /// When an operator is pending, the operator count multiplies the motion count
    /// so `2d3w` deletes 6 words (2 × 3).
    private func consumeCount() -> Int {
        let motionCount = countPrefix > 0 ? countPrefix : 1
        let opCount = operatorCount > 0 ? operatorCount : 1
        let total = motionCount * opCount
        countPrefix = 0
        operatorCount = 0
        return total
    }

    // MARK: - Normal Mode

    private func processNormal(_ char: Character, shift: Bool) -> Bool { // swiftlint:disable:this function_body_length cyclomatic_complexity
        guard let buffer else { return false }

        // Pending char-after-prefix sequences
        if let req = pendingFindChar {
            pendingFindChar = nil
            if char == "\u{1B}" { return true }
            return executeFindChar(char, request: req, in: buffer)
        }
        if pendingReplaceChar {
            pendingReplaceChar = false
            if char == "\u{1B}" { return true }
            return executeReplaceChar(char, in: buffer)
        }

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
            return handlePendingG(char, in: buffer)
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
            return handleG(in: buffer)
        case "W":
            let count = consumeCount()
            executeMotion(in: buffer) { self.bigWordForward(count, in: buffer) }
            return true
        case "B":
            let count = consumeCount()
            executeMotion(in: buffer) { self.bigWordBackward(count, in: buffer) }
            return true
        case "E":
            let count = consumeCount()
            executeMotion(in: buffer, inclusive: true) { self.bigWordEndMotion(count, in: buffer) }
            return true

        // -- Insert mode entry --
        case "i":
            countPrefix = 0
            mode = .insert
            return true
        case "I":
            countPrefix = 0
            let target = firstNonBlankOffset(from: buffer.selectedRange().location, in: buffer)
            buffer.setSelectedRange(NSRange(location: target, length: 0))
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
                deleteLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.delete)
            return true
        case "y":
            if pendingOperator == .yank {
                yankLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.yank)
            return true
        case "c":
            if pendingOperator == .change {
                changeLine(consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.change)
            return true

        // -- Shortcuts: D = d$, Y = yy, C = c$ --
        case "D":
            beginOperator(.delete)
            executeMotion(in: buffer, inclusive: true) { self.moveToLineEnd(in: buffer) }
            return true
        case "Y":
            yankLine(consumeCount(), in: buffer)
            return true
        case "C":
            beginOperator(.change)
            executeMotion(in: buffer, inclusive: true) { self.moveToLineEnd(in: buffer) }
            return true

        // -- X: delete char before cursor (with count) --
        case "X":
            deleteCharBeforeCursor(consumeCount(), in: buffer)
            return true

        // -- s/S substitute --
        case "s":
            let count = consumeCount()
            substituteChars(count, in: buffer)
            return true
        case "S":
            changeLine(consumeCount(), in: buffer)
            return true

        // -- J: Join lines (with space) --
        case "J":
            joinLines(consumeCount(), withSpace: true, in: buffer)
            return true

        // -- f/F/t/T find-character --
        case "f":
            pendingFindChar = VimFindCharRequest(forward: true, till: false)
            return true
        case "F":
            pendingFindChar = VimFindCharRequest(forward: false, till: false)
            return true
        case "t":
            pendingFindChar = VimFindCharRequest(forward: true, till: true)
            return true
        case "T":
            pendingFindChar = VimFindCharRequest(forward: false, till: true)
            return true
        case ";":
            guard let last = lastFindChar else { return true }
            let req = VimFindCharRequest(forward: last.forward, till: last.till)
            _ = executeFindChar(last.char, request: req, in: buffer)
            return true
        case ",":
            guard let last = lastFindChar else { return true }
            let req = VimFindCharRequest(forward: !last.forward, till: last.till)
            _ = executeFindChar(last.char, request: req, in: buffer)
            return true

        // -- r{char} single-char replace --
        case "r":
            pendingReplaceChar = true
            return true
        // -- R: enter Replace overwrite mode --
        case "R":
            countPrefix = 0
            operatorCount = 0
            mode = .replace
            return true

        // -- ~: toggle case under cursor (count chars), or g~~ line variant --
        case "~":
            if pendingOperator == .toggleCase {
                applyCaseToLine(.toggleCase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            toggleCaseUnderCursor(consumeCount(), in: buffer)
            return true

        // -- >> and <<: indent / outdent line --
        case ">":
            if pendingOperator == .indent {
                indentLine(consumeCount(), outdent: false, in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.indent)
            return true
        case "<":
            if pendingOperator == .outdent {
                indentLine(consumeCount(), outdent: true, in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.outdent)
            return true

        // -- ? reverse search --
        case "?":
            countPrefix = 0
            operatorCount = 0
            mode = .commandLine(buffer: "?")
            return true

        // -- % bracket match --
        case "%":
            jumpToMatchingBracket(in: buffer)
            return true

        // -- H/M/L screen motions --
        case "H":
            jumpToVisibleLine(.top, in: buffer)
            return true
        case "M":
            jumpToVisibleLine(.middle, in: buffer)
            return true
        case "L":
            jumpToVisibleLine(.bottom, in: buffer)
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

        // -- Undo / line undo / case-line --
        case "u":
            if pendingOperator == .lowercase {
                applyCaseToLine(.lowercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            let count = consumeCount()
            for _ in 0..<count { buffer.undo() }
            return true
        case "U":
            if pendingOperator == .uppercase {
                applyCaseToLine(.uppercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            let count = consumeCount()
            for _ in 0..<count { buffer.undo() }
            return true

        // -- x: delete character under cursor --
        case "x":
            deleteCharUnderCursor(consumeCount(), in: buffer)
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
            lastInsertOffset = buffer?.selectedRange().location
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

    private func processReplace(_ char: Character) -> Bool {
        guard let buffer else { return false }
        if char == "\u{1B}" {
            mode = .normal
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            if pos > lineRange.location {
                buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
            }
            return true
        }
        if char == "\r" || char == "\n" {
            return false
        }
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        if pos < contentEnd {
            buffer.replaceCharacters(in: NSRange(location: pos, length: 1), with: String(char))
        } else {
            buffer.replaceCharacters(in: NSRange(location: pos, length: 0), with: String(char))
        }
        return true
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
            if char == "J" {
                joinSelectedLines(withSpace: false, in: buffer)
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

        case "J":
            joinSelectedLines(withSpace: true, in: buffer)
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
        // Inclusive motions (like `e`, `$`) include the character at the end position,
        // unless that character is a newline (operators must not consume line terminators).
        if inclusive && rangeEnd < buffer.length && buffer.character(at: rangeEnd) != 0x0A {
            rangeEnd += 1
        }
        let range = NSRange(location: rangeStart, length: rangeEnd - rangeStart)

        executeOperatorOnRange(op, range: range, linewise: false, in: buffer)
        pendingOperator = nil
    }

    private func executeOperatorOnRange(_ op: VimOperator, range: NSRange, linewise: Bool, in buffer: VimTextBuffer) {
        guard range.length > 0 else { return }

        switch op {
        case .delete:
            register.text = buffer.string(in: range)
            register.isLinewise = linewise
            register.syncToPasteboard()
            buffer.replaceCharacters(in: range, with: "")
            let newPos = min(range.location, max(0, buffer.length - 1))
            buffer.setSelectedRange(NSRange(location: max(0, newPos), length: 0))
        case .yank:
            register.text = buffer.string(in: range)
            register.isLinewise = linewise
            register.syncToPasteboard()
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .change:
            register.text = buffer.string(in: range)
            register.isLinewise = linewise
            register.syncToPasteboard()
            buffer.replaceCharacters(in: range, with: "")
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
            mode = .insert
        case .lowercase:
            let transformed = buffer.string(in: range).lowercased()
            buffer.replaceCharacters(in: range, with: transformed)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .uppercase:
            let transformed = buffer.string(in: range).uppercased()
            buffer.replaceCharacters(in: range, with: transformed)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .toggleCase:
            let transformed = toggleCaseTransform(buffer.string(in: range))
            buffer.replaceCharacters(in: range, with: transformed)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .indent:
            applyIndent(in: range, outdent: false, in: buffer)
        case .outdent:
            applyIndent(in: range, outdent: true, in: buffer)
        }
    }

    private func toggleCaseTransform(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let char = Character(scalar)
            if char.isUppercase {
                result.append(char.lowercased())
            } else if char.isLowercase {
                result.append(char.uppercased())
            } else {
                result.append(char)
            }
        }
        return result
    }

    private func applyIndent(in range: NSRange, outdent: Bool, in buffer: VimTextBuffer) {
        let indent = buffer.indentString()
        let nsText = buffer.string(in: range) as NSString
        var lines: [String] = []
        var lineStart = 0
        while lineStart < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
            lines.append(nsText.substring(with: lineRange))
            lineStart = lineRange.location + lineRange.length
        }
        let transformed = lines.map { line -> String in
            if outdent {
                if line.hasPrefix(indent) { return String(line.dropFirst(indent.count)) }
                let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
                return String(stripped)
            }
            return indent + line
        }.joined()
        buffer.replaceCharacters(in: range, with: transformed)
        let firstNonBlank = firstNonBlankOffset(from: range.location, in: buffer)
        buffer.setSelectedRange(NSRange(location: firstNonBlank, length: 0))
    }

    // MARK: - Pending Operator Setup

    /// Capture the current count into operatorCount and set the pending operator.
    private func beginOperator(_ op: VimOperator) {
        operatorCount = countPrefix
        countPrefix = 0
        pendingOperator = op
    }

    /// Run a motion closure, optionally as the target of a pending operator. Inclusive
    /// motions extend the deleted/yanked/changed range by one character at the end.
    private func executeMotion(in buffer: VimTextBuffer, inclusive: Bool = false, _ motion: () -> Void) {
        if let op = pendingOperator {
            executeOperatorWithMotion(op, motion: motion, inclusive: inclusive, in: buffer)
        } else {
            motion()
        }
        goalColumn = nil
    }

    // MARK: - Pending g Dispatch

    private func handlePendingG(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        switch char {
        case "g":
            let count = countPrefix
            countPrefix = 0
            operatorCount = 0
            if let op = pendingOperator {
                executeLinewiseOperator(op, fromOffset: buffer.selectedRange().location,
                                        toLine: count > 0 ? count - 1 : 0, in: buffer)
                pendingOperator = nil
            } else {
                if count > 1 {
                    goToLine(count - 1, in: buffer)
                } else {
                    let target = firstNonBlankOffset(from: 0, in: buffer)
                    buffer.setSelectedRange(NSRange(location: target, length: 0))
                }
            }
            goalColumn = nil
            return true
        case "e":
            let count = consumeCount()
            executeMotion(in: buffer, inclusive: true) { self.wordEndBackwardMotion(count, in: buffer) }
            return true
        case "E":
            let count = consumeCount()
            executeMotion(in: buffer, inclusive: true) { self.bigWordEndBackwardMotion(count, in: buffer) }
            return true
        case "i":
            countPrefix = 0
            operatorCount = 0
            if let target = lastInsertOffset {
                let clamped = min(max(0, target), buffer.length)
                buffer.setSelectedRange(NSRange(location: clamped, length: 0))
            }
            mode = .insert
            return true
        case "J":
            joinLines(consumeCount(), withSpace: false, in: buffer)
            return true
        case "u":
            if pendingOperator == .lowercase {
                applyCaseToLine(.lowercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.lowercase)
            return true
        case "U":
            if pendingOperator == .uppercase {
                applyCaseToLine(.uppercase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.uppercase)
            return true
        case "~":
            if pendingOperator == .toggleCase {
                applyCaseToLine(.toggleCase, count: consumeCount(), in: buffer)
                pendingOperator = nil
                return true
            }
            beginOperator(.toggleCase)
            return true
        default:
            countPrefix = 0
            operatorCount = 0
            pendingOperator = nil
            return true
        }
    }

    // MARK: - G Handling

    private func handleG(in buffer: VimTextBuffer) -> Bool {
        let count = countPrefix
        countPrefix = 0
        let targetLine: Int
        if count > 0 {
            targetLine = min(max(0, count - 1), buffer.lineCount - 1)
        } else {
            targetLine = max(0, buffer.lineCount - 1)
        }
        if let op = pendingOperator {
            executeLinewiseOperator(op, fromOffset: buffer.selectedRange().location,
                                    toLine: targetLine, in: buffer)
            pendingOperator = nil
            operatorCount = 0
        } else {
            let lineStart = buffer.offset(forLine: targetLine, column: 0)
            let target = firstNonBlankOffset(from: lineStart, in: buffer)
            buffer.setSelectedRange(NSRange(location: target, length: 0))
        }
        goalColumn = nil
        return true
    }

    /// Apply an operator linewise from the current line to the line of the target offset.
    private func executeLinewiseOperator(_ op: VimOperator, fromOffset: Int, toLine: Int, in buffer: VimTextBuffer) {
        let startLineRange = buffer.lineRange(forOffset: fromOffset)
        let targetOffset = buffer.offset(forLine: toLine, column: 0)
        let endLineRange = buffer.lineRange(forOffset: targetOffset)
        let rangeStart = min(startLineRange.location, endLineRange.location)
        let rangeEnd = max(startLineRange.location + startLineRange.length,
                          endLineRange.location + endLineRange.length)
        let range = NSRange(location: rangeStart, length: rangeEnd - rangeStart)
        executeOperatorOnRange(op, range: range, linewise: true, in: buffer)
    }

    // MARK: - Big-Word Motions

    private func bigWordForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.bigWordBoundary(forward: true, from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func bigWordBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.bigWordBoundary(forward: false, from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func bigWordEndMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.bigWordEnd(from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func wordEndBackwardMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.wordEndBackward(from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func bigWordEndBackwardMotion(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count { pos = buffer.bigWordEndBackward(from: pos) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    // MARK: - x / X / s

    private func deleteCharUnderCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let deleteCount = min(count, max(0, contentEnd - pos))
        guard deleteCount > 0 else { return }
        let range = NSRange(location: pos, length: deleteCount)
        register.text = buffer.string(in: range)
        register.isLinewise = false
        register.syncToPasteboard()
        buffer.replaceCharacters(in: range, with: "")
        let newContentEnd = contentEnd - deleteCount
        if pos >= newContentEnd && newContentEnd > lineRange.location {
            buffer.setSelectedRange(NSRange(location: newContentEnd - 1, length: 0))
        } else {
            buffer.setSelectedRange(NSRange(location: pos, length: 0))
        }
    }

    private func deleteCharBeforeCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let deleteCount = min(count, pos - lineRange.location)
        guard deleteCount > 0 else { return }
        let start = pos - deleteCount
        let range = NSRange(location: start, length: deleteCount)
        register.text = buffer.string(in: range)
        register.isLinewise = false
        register.syncToPasteboard()
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: start, length: 0))
    }

    private func substituteChars(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let deleteCount = min(count, max(0, contentEnd - pos))
        guard deleteCount > 0 else { mode = .insert; return }
        let range = NSRange(location: pos, length: deleteCount)
        register.text = buffer.string(in: range)
        register.isLinewise = false
        register.syncToPasteboard()
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
        mode = .insert
    }

    // MARK: - Join Lines (J, gJ)

    /// Join `count` lines starting from the current line into one.
    /// `withSpace = true` is `J` — inserts a single space at each join unless the join
    /// is adjacent to whitespace, the next-line content is empty, or starts with `)`.
    /// `withSpace = false` is `gJ` — never inserts a space and preserves leading whitespace.
    /// Minimum count is two lines (default count of 1 still joins one line below).
    func joinLines(_ count: Int, withSpace: Bool, in buffer: VimTextBuffer) {
        let joinCount = max(count - 1, 1)
        for _ in 0..<joinCount {
            guard performSingleJoin(withSpace: withSpace, in: buffer) else { return }
        }
    }

    // MARK: - Find Character (f/F/t/T)

    private func executeFindChar(_ char: Character, request: VimFindCharRequest, in buffer: VimTextBuffer) -> Bool {
        lastFindChar = VimLastFindChar(char: char, forward: request.forward, till: request.till)
        guard let scalar = char.unicodeScalars.first else { return true }
        let target = unichar(scalar.value)
        let count = consumeCount()
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd

        var resolved: Int?
        if request.forward {
            // For `t` (till) we skip the adjacent target so already-adjacent doesn't no-op.
            let initial = request.till ? pos + 2 : pos + 1
            var scanStart = min(initial, contentEnd)
            for _ in 0..<count {
                resolved = nil
                var idx = scanStart
                while idx < contentEnd {
                    if buffer.character(at: idx) == target {
                        resolved = idx
                        scanStart = idx + 1
                        break
                    }
                    idx += 1
                }
                if resolved == nil { break }
            }
        } else {
            let initial = request.till ? pos - 2 : pos - 1
            var scanStart = initial
            for _ in 0..<count {
                resolved = nil
                var idx = scanStart
                while idx >= lineRange.location {
                    if buffer.character(at: idx) == target {
                        resolved = idx
                        scanStart = idx - 1
                        break
                    }
                    idx -= 1
                }
                if resolved == nil { break }
            }
        }

        guard var finalPos = resolved else { return true }
        if request.till {
            finalPos += request.forward ? -1 : 1
        }
        executeMotion(in: buffer, inclusive: true) {
            buffer.setSelectedRange(NSRange(location: finalPos, length: 0))
        }
        return true
    }

    // MARK: - r{char} Replace

    private func executeReplaceChar(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        let count = consumeCount()
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        guard pos + count <= contentEnd else { return true }
        let replacement: String
        if char == "\r" || char == "\n" {
            replacement = String(repeating: "\n", count: count)
        } else {
            replacement = String(repeating: char, count: count)
        }
        let range = NSRange(location: pos, length: count)
        buffer.replaceCharacters(in: range, with: replacement)
        buffer.setSelectedRange(NSRange(location: pos + count - 1, length: 0))
        return true
    }

    // MARK: - ~ Toggle Case under Cursor

    private func toggleCaseUnderCursor(_ count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let toggleCount = min(count, max(0, contentEnd - pos))
        guard toggleCount > 0 else { return }
        let range = NSRange(location: pos, length: toggleCount)
        let transformed = toggleCaseTransform(buffer.string(in: range))
        buffer.replaceCharacters(in: range, with: transformed)
        let newPos = min(pos + toggleCount, contentEnd > lineRange.location ? contentEnd - 1 : lineRange.location)
        buffer.setSelectedRange(NSRange(location: newPos, length: 0))
    }

    private func applyCaseToLine(_ op: VimOperator, count: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let lineEnd = endOffset
        let contentEnd = lineEnd > startRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        let range = NSRange(location: startRange.location, length: contentEnd - startRange.location)
        guard range.length > 0 else { return }
        let original = buffer.string(in: range)
        let transformed: String
        switch op {
        case .lowercase: transformed = original.lowercased()
        case .uppercase: transformed = original.uppercased()
        case .toggleCase: transformed = toggleCaseTransform(original)
        default: return
        }
        buffer.replaceCharacters(in: range, with: transformed)
        buffer.setSelectedRange(NSRange(location: startRange.location, length: 0))
    }

    // MARK: - Indent Line (>>, <<)

    private func indentLine(_ count: Int, outdent: Bool, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let startRange = buffer.lineRange(forOffset: pos)
        var endOffset = startRange.location + startRange.length
        for _ in 1..<count {
            if endOffset < buffer.length {
                let nextLineRange = buffer.lineRange(forOffset: endOffset)
                endOffset = nextLineRange.location + nextLineRange.length
            }
        }
        let range = NSRange(location: startRange.location, length: endOffset - startRange.location)
        applyIndent(in: range, outdent: outdent, in: buffer)
    }

    // MARK: - % Matching Bracket

    private func jumpToMatchingBracket(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        var scan = pos
        while scan < contentEnd {
            if let target = buffer.matchingBracket(at: scan) {
                buffer.setSelectedRange(NSRange(location: target, length: 0))
                return
            }
            scan += 1
        }
    }

    // MARK: - H/M/L Screen Motions

    private enum ScreenPosition { case top, middle, bottom }

    private func jumpToVisibleLine(_ position: ScreenPosition, in buffer: VimTextBuffer) {
        let (firstLine, lastLine) = buffer.visibleLineRange()
        let targetLine: Int
        switch position {
        case .top: targetLine = firstLine
        case .bottom: targetLine = lastLine
        case .middle: targetLine = (firstLine + lastLine) / 2
        }
        let lineStart = buffer.offset(forLine: targetLine, column: 0)
        let target = firstNonBlankOffset(from: lineStart, in: buffer)
        buffer.setSelectedRange(NSRange(location: target, length: 0))
        goalColumn = nil
    }

    /// Join every line covered by the current visual selection. After joining, return to
    /// normal mode.
    private func joinSelectedLines(withSpace: Bool, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        let startLineRange = buffer.lineRange(forOffset: sel.location)
        let lastInclusiveOffset = max(sel.location, sel.location + sel.length - 1)
        let endLineRange = buffer.lineRange(forOffset: lastInclusiveOffset)
        let startLine = buffer.lineAndColumn(forOffset: startLineRange.location).line
        let endLine = buffer.lineAndColumn(forOffset: endLineRange.location).line
        let linesCovered = max(1, endLine - startLine + 1)
        buffer.setSelectedRange(NSRange(location: startLineRange.location, length: 0))
        let joins = max(linesCovered - 1, 1)
        for _ in 0..<joins {
            guard performSingleJoin(withSpace: withSpace, in: buffer) else { break }
        }
        mode = .normal
    }

    /// Performs one join (current line + next). Returns false if no next line.
    private func performSingleJoin(withSpace: Bool, in buffer: VimTextBuffer) -> Bool {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        guard lineEnd < buffer.length else { return false }
        guard lineEnd > lineRange.location && buffer.character(at: lineEnd - 1) == 0x0A else {
            return false
        }
        let newlineOffset = lineEnd - 1
        var stripStart = lineEnd
        if withSpace {
            while stripStart < buffer.length {
                let ch = buffer.character(at: stripStart)
                if ch == 0x20 || ch == 0x09 { stripStart += 1 } else { break }
            }
        }
        let nextLineIsEmpty = stripStart >= buffer.length
            || buffer.character(at: stripStart) == 0x0A
        let lastContentOffset = newlineOffset
        let lastContent: unichar? = lastContentOffset > lineRange.location
            ? buffer.character(at: lastContentOffset - 1) : nil
        let lastIsWhitespace = lastContent == 0x20 || lastContent == 0x09
        let currentLineIsEmpty = lineEnd == lineRange.location + 1 && lastContent == nil
        let nextChar: unichar? = stripStart < buffer.length
            ? buffer.character(at: stripStart) : nil
        let nextIsClosingParen = nextChar == 0x29
        let shouldInsertSpace = withSpace
            && !nextLineIsEmpty
            && !lastIsWhitespace
            && !nextIsClosingParen
            && !currentLineIsEmpty
        let replacementRange = NSRange(location: newlineOffset, length: stripStart - newlineOffset)
        let replacement = shouldInsertSpace ? " " : ""
        buffer.replaceCharacters(in: replacementRange, with: replacement)
        let cursorTarget = shouldInsertSpace ? newlineOffset : newlineOffset
        let clamped = min(cursorTarget, max(0, buffer.length - 1))
        buffer.setSelectedRange(NSRange(location: clamped, length: 0))
        return true
    }
}
