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

/// The kind of edit recorded for the `.` repeat command.
enum VimDotKind {
    case deleteCharForward(count: Int)
    case deleteCharBackward(count: Int)
    case operatorWithMotion(op: VimOperator, motion: Character, shift: Bool, count: Int)
    case operatorDoubled(op: VimOperator, count: Int)
    case toggleCase(count: Int)
    case joinLines(withSpace: Bool, count: Int)
    case replaceChar(char: Character, count: Int)
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
    private var pendingMarkSet: Bool = false
    private var pendingMarkJumpExact: Bool?
    private var pendingRegisterSelect: Bool = false
    private var pendingReplaceCharForVisual: Bool = false
    private var pendingZ: Bool = false
    private var pendingTextObject: Bool = false
    private var pendingTextObjectAround: Bool = false
    private var selectedRegister: Character?
    private var lastFindChar: VimLastFindChar?
    private var lastDotKind: VimDotKind?
    private var marks: [Character: Int] = [:]
    private var namedRegisters: [Character: VimRegister] = [:]
    /// Numbered registers "0..."9 — "0 holds last yank, "1 holds most recent delete with
    /// older deletes rotating into "2..."9.
    private var numberedRegisters: [VimRegister] = Array(repeating: VimRegister(), count: 10)
    private var editsOnCurrentLine: Int = 0
    private var lastEditedLine: Int?
    private var lastJumpOrigin: Int?
    private var lastVisualStart: Int?
    private var lastVisualEnd: Int?
    private var lastVisualLinewise: Bool = false
    private var lastSearchPattern: String?
    private var lastSearchForward: Bool = true
    private var macroRecording: Character?
    private var macroBuffers: [Character: [(Character, Bool)]] = [:]
    private var lastInvokedMacro: Character?
    private var pendingMacroTarget: MacroPendingKind?
    private var pendingMacroCount: Int = 1
    private var macroPlaybackDepth: Int = 0
    private enum MacroPendingKind { case recordTarget, replayTarget }
    private var pendingBracket: BracketPending?
    private enum BracketPending { case openBracket, closeBracket }

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
        let recordingTarget = macroRecording
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
        // Append to the active macro register if we were recording before this key
        // ran (so the register-arm `q{a}` keystroke itself is not captured).
        if let target = recordingTarget, macroRecording == target {
            macroBuffers[target, default: []].append((char, shift))
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

        // Ctrl-prefixed normal-mode commands: number adjust and scroll motions.
        if let consumed = handleNormalControl(char, in: buffer) {
            return consumed
        }

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
        if pendingMarkSet {
            pendingMarkSet = false
            if char == "\u{1B}" { return true }
            marks[char] = buffer.selectedRange().location
            return true
        }
        if let exact = pendingMarkJumpExact {
            pendingMarkJumpExact = nil
            if char == "\u{1B}" { return true }
            jumpToMark(char, exact: exact, in: buffer)
            return true
        }
        if pendingRegisterSelect {
            pendingRegisterSelect = false
            if char == "\u{1B}" { return true }
            selectedRegister = char
            return true
        }
        if pendingZ {
            pendingZ = false
            switch char {
            case "t", "z", "b": return true
            default: return true
            }
        }
        if pendingTextObject {
            pendingTextObject = false
            if char == "\u{1B}" {
                pendingOperator = nil
                return true
            }
            return executeTextObject(char, around: pendingTextObjectAround, in: buffer)
        }
        if let kind = pendingMacroTarget {
            pendingMacroTarget = nil
            if char == "\u{1B}" { return true }
            handleMacroTarget(kind: kind, register: char)
            return true
        }
        if let bracketKind = pendingBracket {
            pendingBracket = nil
            if char == "\u{1B}" { return true }
            switch (bracketKind, char) {
            case (.openBracket, "["): sectionBackward(in: buffer); return true
            case (.closeBracket, "]"): sectionForward(in: buffer); return true
            default: return true
            }
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
            let op = pendingOperator
            if let op {
                executeOperatorWithMotion(op, motion: { self.wordForward(count, in: buffer) }, in: buffer)
                recordDot(.operatorWithMotion(op: op, motion: "w", shift: false, count: count))
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
            if pendingOperator != nil {
                pendingTextObject = true
                pendingTextObjectAround = false
                return true
            }
            countPrefix = 0
            mode = .insert
            return true
        case "a":
            if pendingOperator != nil {
                pendingTextObject = true
                pendingTextObjectAround = true
                return true
            }
            countPrefix = 0
            let pos = buffer.selectedRange().location
            if pos < buffer.length {
                buffer.setSelectedRange(NSRange(location: pos + 1, length: 0))
            }
            mode = .insert
            return true
        case "I":
            countPrefix = 0
            let target = firstNonBlankOffset(from: buffer.selectedRange().location, in: buffer)
            buffer.setSelectedRange(NSRange(location: target, length: 0))
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

        // -- Search repeat / word-under-cursor --
        case "n":
            let count = consumeCount()
            for _ in 0..<count { searchNext(in: buffer, reverseDirection: false) }
            return true
        case "N":
            let count = consumeCount()
            for _ in 0..<count { searchNext(in: buffer, reverseDirection: true) }
            return true
        case "*":
            searchWordUnderCursor(forward: true, in: buffer)
            return true
        case "#":
            searchWordUnderCursor(forward: false, in: buffer)
            return true

        // -- Marks and register selection --
        case "m":
            pendingMarkSet = true
            return true
        case "'":
            pendingMarkJumpExact = false
            return true
        case "`":
            pendingMarkJumpExact = true
            return true
        case "\"":
            pendingRegisterSelect = true
            return true

        // -- . repeat last change --
        case ".":
            let count = consumeCount()
            replayLastDot(count: count, in: buffer)
            return true

        // -- Sentence / paragraph / section motions --
        case "(":
            sentenceBackward(consumeCount(), in: buffer)
            return true
        case ")":
            sentenceForward(consumeCount(), in: buffer)
            return true
        case "{":
            paragraphBackward(consumeCount(), in: buffer)
            return true
        case "}":
            paragraphForward(consumeCount(), in: buffer)
            return true
        case "[":
            pendingBracket = .openBracket
            return true
        case "]":
            pendingBracket = .closeBracket
            return true

        // -- Macros --
        case "q":
            if macroRecording != nil {
                macroRecording = nil
            } else {
                pendingMacroTarget = .recordTarget
            }
            return true
        case "@":
            pendingMacroCount = consumeCount()
            pendingMacroTarget = .replayTarget
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

        // -- z* viewport-positioning commands --
        case "z":
            pendingZ = true
            return true

        // -- Paste --
        case "p":
            let count = consumeCount()
            for _ in 0..<count { paste(after: true, in: buffer) }
            return true
        case "P":
            let count = consumeCount()
            for _ in 0..<count { paste(after: false, in: buffer) }
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
            // U (without count) undoes every edit made on the current line since the
            // cursor arrived. A user-provided count overrides this.
            let explicitCount = countPrefix
            countPrefix = 0
            operatorCount = 0
            let undoCount: Int
            if explicitCount > 0 {
                undoCount = explicitCount
            } else if editsOnCurrentLine > 0 {
                undoCount = editsOnCurrentLine
            } else {
                undoCount = 1
            }
            for _ in 0..<undoCount { buffer.undo() }
            editsOnCurrentLine = 0
            return true

        // -- x: delete character under cursor --
        case "x":
            let count = consumeCount()
            deleteCharUnderCursor(count, in: buffer)
            recordDot(.deleteCharForward(count: count))
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
        if char == "\u{1B}" {
            lastInsertOffset = buffer?.selectedRange().location
            mode = .normal
            if let buffer, buffer.selectedRange().location > 0 {
                let pos = buffer.selectedRange().location
                let lineRange = buffer.lineRange(forOffset: pos)
                if pos > lineRange.location {
                    buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
                }
            }
            return true
        }
        if let buffer, handleInsertModeControl(char, in: buffer) {
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
        if handleInsertModeControl(char, in: buffer) { return true }
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

    /// Handle Ctrl-prefixed editing commands available in insert and replace modes.
    /// Returns true when the engine consumed the keystroke.
    private func handleInsertModeControl(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        switch char {
        case "\u{17}": // Ctrl+W — delete previous word
            deleteWordBackwardInInsert(in: buffer)
            return true
        case "\u{15}": // Ctrl+U — delete to line start
            deleteToLineStartInInsert(in: buffer)
            return true
        case "\u{08}": // Ctrl+H — backspace
            backspaceInInsert(in: buffer)
            return true
        case "\u{14}": // Ctrl+T — indent current line
            indentLineInInsert(outdent: false, in: buffer)
            return true
        case "\u{04}": // Ctrl+D — outdent current line
            indentLineInInsert(outdent: true, in: buffer)
            return true
        default:
            return false
        }
    }

    private func deleteWordBackwardInInsert(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos > 0 else { return }
        let lineStart = buffer.lineRange(forOffset: pos).location
        guard pos > lineStart else { return }
        let target = max(lineStart, buffer.wordBoundary(forward: false, from: pos))
        let range = NSRange(location: target, length: pos - target)
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: target, length: 0))
    }

    private func deleteToLineStartInInsert(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineStart = buffer.lineRange(forOffset: pos).location
        guard pos > lineStart else { return }
        let range = NSRange(location: lineStart, length: pos - lineStart)
        buffer.replaceCharacters(in: range, with: "")
        buffer.setSelectedRange(NSRange(location: lineStart, length: 0))
    }

    private func backspaceInInsert(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos > 0 else { return }
        buffer.replaceCharacters(in: NSRange(location: pos - 1, length: 1), with: "")
        buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
    }

    private func indentLineInInsert(outdent: Bool, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let indent = buffer.indentString()
        if outdent {
            let line = buffer.string(in: lineRange) as NSString
            var stripCount = 0
            while stripCount < indent.count && stripCount < line.length
                && (line.character(at: stripCount) == 0x20 || line.character(at: stripCount) == 0x09) {
                stripCount += 1
            }
            guard stripCount > 0 else { return }
            buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: stripCount), with: "")
            buffer.setSelectedRange(NSRange(location: max(lineRange.location, pos - stripCount), length: 0))
        } else {
            buffer.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: indent)
            buffer.setSelectedRange(NSRange(location: pos + indent.count, length: 0))
        }
    }

    // MARK: - Visual Mode

    private func processVisual(_ char: Character, shift: Bool) -> Bool { // swiftlint:disable:this function_body_length cyclomatic_complexity
        guard let buffer else { return false }

        if pendingReplaceCharForVisual {
            pendingReplaceCharForVisual = false
            if char == "\u{1B}" { return true }
            replaceVisualSelectionWithChar(char, in: buffer)
            return true
        }
        if pendingTextObject {
            pendingTextObject = false
            if char == "\u{1B}" { return true }
            return executeTextObject(char, around: pendingTextObjectAround, in: buffer)
        }

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
            recordVisualSelection(linewise: isLinewise, in: buffer)
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

        case "o":
            swapVisualAnchorAndCursor(in: buffer, linewise: isLinewise)
            return true

        case "~":
            applyCaseToVisualSelection(.toggleCase, linewise: isLinewise, in: buffer)
            return true
        case "u":
            applyCaseToVisualSelection(.lowercase, linewise: isLinewise, in: buffer)
            return true
        case "U":
            applyCaseToVisualSelection(.uppercase, linewise: isLinewise, in: buffer)
            return true

        case "r":
            pendingReplaceCharForVisual = true
            return true

        case "i":
            pendingTextObject = true
            pendingTextObjectAround = false
            return true
        case "a":
            pendingTextObject = true
            pendingTextObjectAround = true
            return true
        case "I":
            let sel = buffer.selectedRange()
            buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
            mode = .insert
            return true
        case "A":
            let sel = buffer.selectedRange()
            let endPos = sel.location + sel.length
            let clamped = min(endPos, buffer.length)
            buffer.setSelectedRange(NSRange(location: clamped, length: 0))
            mode = .insert
            return true

        case "p", "P":
            pasteOverVisualSelection(in: buffer)
            return true

        case "d", "x": // Delete selection
            let sel = buffer.selectedRange()
            recordVisualSelection(linewise: isLinewise, in: buffer)
            if sel.length > 0 {
                writeToActiveRegister(text: buffer.string(in: sel), linewise: isLinewise, asDelete: true)
                adjustMarksForEdit(in: sel, replacementLength: 0)
                buffer.replaceCharacters(in: sel, with: "")
            }
            mode = .normal
            return true

        case "y": // Yank selection
            let sel = buffer.selectedRange()
            recordVisualSelection(linewise: isLinewise, in: buffer)
            if sel.length > 0 {
                writeToActiveRegister(text: buffer.string(in: sel), linewise: isLinewise, asDelete: false)
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
                if isLinewise {
                    // Keep the trailing newline so the line scaffold survives the edit.
                    let trimmed = sel.length > 0
                        && sel.location + sel.length - 1 < buffer.length
                        && buffer.character(at: sel.location + sel.length - 1) == 0x0A
                        ? NSRange(location: sel.location, length: sel.length - 1) : sel
                    buffer.replaceCharacters(in: trimmed, with: "")
                    buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
                } else {
                    buffer.replaceCharacters(in: sel, with: "")
                }
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
            let prefix = commandBuffer.first
            let body = String(commandBuffer.dropFirst())
            mode = .normal
            if prefix == "/" {
                runSearch(pattern: body, forward: true)
            } else if prefix == "?" {
                runSearch(pattern: body, forward: false)
            } else {
                onCommand?(body)
            }
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
        let isOperator = pendingOperator != nil
        for i in 0..<count {
            let prev = pos
            let next = buffer.wordBoundary(forward: true, from: pos)
            if isOperator && i == count - 1 {
                let prevLineRange = buffer.lineRange(forOffset: prev)
                let nextLineRange = buffer.lineRange(forOffset: min(next, buffer.length))
                if prevLineRange.location != nextLineRange.location {
                    let lineEnd = prevLineRange.location + prevLineRange.length
                    let contentEnd = lineEnd > prevLineRange.location
                        && lineEnd <= buffer.length
                        && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
                    pos = contentEnd
                    break
                }
            }
            pos = next
        }
        if !isOperator { pos = clampToContentPosition(pos, in: buffer) }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    /// Snap a motion target back to a valid normal-mode cursor position — never past
    /// the buffer end and never on a newline character (vim's normal mode keeps the
    /// cursor on a content character of some line).
    private func clampToContentPosition(_ offset: Int, in buffer: VimTextBuffer) -> Int {
        guard buffer.length > 0 else { return 0 }
        var pos = min(max(0, offset), buffer.length - 1)
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let endsInNewline = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A
        let contentEnd = endsInNewline ? lineEnd - 1 : lineEnd
        if pos >= contentEnd && contentEnd > lineRange.location {
            pos = contentEnd - 1
        }
        return pos
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
        writeToActiveRegister(text: buffer.string(in: deleteRange), linewise: true, asDelete: true)
        adjustMarksForEdit(in: deleteRange, replacementLength: 0)
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
        writeToActiveRegister(text: buffer.string(in: yankRange), linewise: true, asDelete: false)
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
        writeToActiveRegister(text: buffer.string(in: deleteRange), linewise: true, asDelete: true)
        adjustMarksForEdit(in: deleteRange, replacementLength: 0)
        buffer.replaceCharacters(in: deleteRange, with: "")
        buffer.setSelectedRange(NSRange(location: startRange.location, length: 0))
        mode = .insert
    }

    // MARK: - Paste

    private func paste(after: Bool, in buffer: VimTextBuffer) {
        let source = activePasteRegister()
        guard !source.text.isEmpty else { return }

        let pos = buffer.selectedRange().location

        if source.isLinewise {
            if after {
                let lineRange = buffer.lineRange(forOffset: pos)
                let insertPos = lineRange.location + lineRange.length
                var text = source.text
                let nsText = text as NSString
                if nsText.length == 0 || nsText.character(at: nsText.length - 1) != 0x0A {
                    text += "\n"
                }
                buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: text)
                buffer.setSelectedRange(NSRange(location: insertPos, length: 0))
            } else {
                let lineRange = buffer.lineRange(forOffset: pos)
                var text = source.text
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
                buffer.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: source.text)
                let newPos = insertPos + (source.text as NSString).length - 1
                buffer.setSelectedRange(NSRange(location: max(insertPos, newPos), length: 0))
            } else {
                buffer.replaceCharacters(in: NSRange(location: pos, length: 0), with: source.text)
                let newPos = pos + (source.text as NSString).length - 1
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
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: true)
            buffer.replaceCharacters(in: range, with: "")
            adjustMarksForEdit(in: range, replacementLength: 0)
            let newPos = min(range.location, max(0, buffer.length - 1))
            buffer.setSelectedRange(NSRange(location: max(0, newPos), length: 0))
        case .yank:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: false)
            buffer.setSelectedRange(NSRange(location: range.location, length: 0))
        case .change:
            let text = buffer.string(in: range)
            writeToActiveRegister(text: text, linewise: linewise, asDelete: true)
            buffer.replaceCharacters(in: range, with: "")
            adjustMarksForEdit(in: range, replacementLength: 0)
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
        case "v":
            countPrefix = 0
            operatorCount = 0
            reselectLastVisual(in: buffer)
            return true
        case "j":
            // gj — display-line down (same as j for non-wrapping lines)
            let count = consumeCount()
            moveDown(count, in: buffer)
            return true
        case "k":
            let count = consumeCount()
            moveUp(count, in: buffer)
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
            let origin = buffer.selectedRange().location
            let lineStart = buffer.offset(forLine: targetLine, column: 0)
            let target = firstNonBlankOffset(from: lineStart, in: buffer)
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
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
        let isOperator = pendingOperator != nil
        for _ in 0..<count { pos = buffer.bigWordBoundary(forward: true, from: pos) }
        if !isOperator { pos = clampToContentPosition(pos, in: buffer) }
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
        writeToActiveRegister(text: buffer.string(in: range), linewise: false, asDelete: true)
        adjustMarksForEdit(in: range, replacementLength: 0)
        noteEdit(at: pos, in: buffer)
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

    // MARK: - Edit Tracking (for U line undo)

    private func noteEdit(at offset: Int, in buffer: VimTextBuffer) {
        let line = buffer.lineAndColumn(forOffset: offset).line
        if let last = lastEditedLine, last == line {
            editsOnCurrentLine += 1
        } else {
            editsOnCurrentLine = 1
            lastEditedLine = line
        }
    }

    // MARK: - Register Routing

    /// Write the captured text to the appropriate register(s):
    /// - The unnamed register (always)
    /// - Numbered "0 (for yank) or "1 with rotation (for delete)
    /// - The user-selected named register if `"a`..`"z` was active
    /// - Lowercase named registers overwrite; uppercase named registers append
    private func writeToActiveRegister(text: String, linewise: Bool, asDelete: Bool) {
        let entry = VimRegister(text: text, isLinewise: linewise)
        register = entry
        register.syncToPasteboard()
        if asDelete {
            for i in stride(from: 9, to: 1, by: -1) {
                numberedRegisters[i] = numberedRegisters[i - 1]
            }
            numberedRegisters[1] = entry
        } else {
            numberedRegisters[0] = entry
        }
        if let name = selectedRegister, name != "_" {
            let isAppend = name.isUppercase
            let key: Character = isAppend ? Character(name.lowercased()) : name
            if isAppend, let existing = namedRegisters[key], !existing.text.isEmpty {
                let merged = existing.text + text
                namedRegisters[key] = VimRegister(text: merged, isLinewise: existing.isLinewise || linewise)
            } else {
                namedRegisters[key] = entry
            }
        }
        selectedRegister = nil
    }

    /// Returns the register that p/P should read from — falls back to the unnamed register.
    private func activePasteRegister() -> VimRegister {
        defer { selectedRegister = nil }
        if let name = selectedRegister {
            if let digit = name.wholeNumberValue, digit >= 0 && digit < 10 {
                return numberedRegisters[digit]
            }
            let key = name.isUppercase ? Character(name.lowercased()) : name
            return namedRegisters[key] ?? VimRegister()
        }
        return register
    }

    // MARK: - Marks

    private func jumpToMark(_ name: Character, exact: Bool, in buffer: VimTextBuffer) {
        if name == "'" || name == "`" {
            if let origin = lastJumpOrigin {
                let originPos = buffer.selectedRange().location
                let clamped = min(max(0, origin), buffer.length)
                buffer.setSelectedRange(NSRange(location: clamped, length: 0))
                lastJumpOrigin = originPos
            }
            return
        }
        if name == "<", let start = lastVisualStart {
            let originPos = buffer.selectedRange().location
            buffer.setSelectedRange(NSRange(location: min(max(0, start), buffer.length), length: 0))
            lastJumpOrigin = originPos
            return
        }
        if name == ">", let end = lastVisualEnd {
            let originPos = buffer.selectedRange().location
            buffer.setSelectedRange(NSRange(location: min(max(0, end), buffer.length), length: 0))
            lastJumpOrigin = originPos
            return
        }
        guard let offset = marks[name] else { return }
        let originPos = buffer.selectedRange().location
        let clamped = min(max(0, offset), buffer.length)
        if exact {
            buffer.setSelectedRange(NSRange(location: clamped, length: 0))
        } else {
            let lineStart = buffer.lineRange(forOffset: clamped).location
            let target = firstNonBlankOffset(from: lineStart, in: buffer)
            buffer.setSelectedRange(NSRange(location: target, length: 0))
        }
        lastJumpOrigin = originPos
    }

    /// Capture the current visual selection so it can be reselected later with gv or
    /// navigated to with `< and `>.
    private func recordVisualSelection(linewise: Bool, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        guard sel.length > 0 else { return }
        lastVisualStart = sel.location
        lastVisualEnd = sel.location + sel.length - 1
        lastVisualLinewise = linewise
    }

    /// Re-enter visual mode using the previously captured selection bounds.
    private func reselectLastVisual(in buffer: VimTextBuffer) {
        guard let start = lastVisualStart, let end = lastVisualEnd, end >= start else { return }
        let clampedStart = min(max(0, start), max(0, buffer.length - 1))
        let clampedEnd = min(max(clampedStart, end), max(clampedStart, buffer.length - 1))
        visualAnchor = clampedStart
        cursorOffset = clampedEnd
        if lastVisualLinewise {
            let startLineRange = buffer.lineRange(forOffset: clampedStart)
            let endLineRange = buffer.lineRange(forOffset: clampedEnd)
            let lineStart = startLineRange.location
            let lineEnd = endLineRange.location + endLineRange.length
            buffer.setSelectedRange(NSRange(location: lineStart, length: lineEnd - lineStart))
            mode = .visual(linewise: true)
        } else {
            let length = clampedEnd - clampedStart + (clampedEnd < buffer.length ? 1 : 0)
            buffer.setSelectedRange(NSRange(location: clampedStart, length: length))
            mode = .visual(linewise: false)
        }
    }

    /// Adjust mark offsets after an edit that inserts or deletes text in the buffer.
    private func adjustMarksForEdit(in editRange: NSRange, replacementLength: Int) {
        let delta = replacementLength - editRange.length
        guard delta != 0 else { return }
        for (key, offset) in marks {
            if offset >= editRange.location + editRange.length {
                marks[key] = offset + delta
            } else if offset >= editRange.location {
                marks[key] = editRange.location
            }
        }
    }

    // MARK: - Visual Selection Operations

    private func swapVisualAnchorAndCursor(in buffer: VimTextBuffer, linewise: Bool) {
        let sel = buffer.selectedRange()
        let cursor = visualCursorEnd(buffer: buffer)
        let otherEnd = cursor == sel.location
            ? sel.location + max(0, sel.length - 1)
            : sel.location
        visualAnchor = cursor
        cursorOffset = otherEnd
        updateVisualSelection(cursorPos: otherEnd, linewise: linewise, in: buffer)
    }

    private func applyCaseToVisualSelection(_ op: VimOperator, linewise: Bool, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        guard sel.length > 0 else { mode = .normal; return }
        let original = buffer.string(in: sel)
        let transformed: String
        switch op {
        case .lowercase: transformed = original.lowercased()
        case .uppercase: transformed = original.uppercased()
        case .toggleCase: transformed = toggleCaseTransform(original)
        default: return
        }
        buffer.replaceCharacters(in: sel, with: transformed)
        buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
        mode = .normal
    }

    private func replaceVisualSelectionWithChar(_ char: Character, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        guard sel.length > 0 else { mode = .normal; return }
        var replacement = ""
        replacement.reserveCapacity(sel.length)
        for i in 0..<sel.length {
            let original = buffer.character(at: sel.location + i)
            if original == 0x0A {
                replacement.append("\n")
            } else {
                replacement.append(char)
            }
        }
        buffer.replaceCharacters(in: sel, with: replacement)
        buffer.setSelectedRange(NSRange(location: sel.location, length: 0))
        mode = .normal
    }

    private func pasteOverVisualSelection(in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        let text = register.text
        guard sel.length > 0 else { mode = .normal; return }
        buffer.replaceCharacters(in: sel, with: text)
        let newPos = sel.location + (text as NSString).length - 1
        buffer.setSelectedRange(NSRange(location: max(sel.location, newPos), length: 0))
        mode = .normal
    }

    // MARK: - . Repeat

    private func recordDot(_ kind: VimDotKind) {
        lastDotKind = kind
    }

    private func replayLastDot(count: Int, in buffer: VimTextBuffer) {
        guard let kind = lastDotKind else { return }
        for _ in 0..<count {
            switch kind {
            case .deleteCharForward(let original):
                deleteCharUnderCursor(original, in: buffer)
            case .deleteCharBackward(let original):
                deleteCharBeforeCursor(original, in: buffer)
            case .operatorWithMotion(let op, let motion, let shift, let original):
                operatorCount = 0
                countPrefix = original
                pendingOperator = op
                _ = processNormal(motion, shift: shift)
            case .operatorDoubled(let op, let original):
                switch op {
                case .delete: deleteLine(original, in: buffer)
                case .yank: yankLine(original, in: buffer)
                case .change: changeLine(original, in: buffer)
                default: break
                }
            case .toggleCase(let original):
                toggleCaseUnderCursor(original, in: buffer)
            case .joinLines(let withSpace, let original):
                joinLines(original, withSpace: withSpace, in: buffer)
            case .replaceChar(let ch, let original):
                let req = VimFindCharRequest(forward: true, till: false)
                pendingReplaceChar = true
                _ = executeReplaceChar(ch, in: buffer)
                _ = req
                _ = original
            }
        }
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

    // MARK: - Ctrl-Prefixed Normal-Mode Commands

    /// Returns the consumed flag for Ctrl-A / Ctrl-X (number adjust) and the scroll
    /// commands Ctrl-D / Ctrl-U / Ctrl-F / Ctrl-B / Ctrl-E / Ctrl-Y. Returns nil when
    /// the keystroke is not one we handle here so the caller can keep processing.
    private func handleNormalControl(_ char: Character, in buffer: VimTextBuffer) -> Bool? {
        switch char {
        case "\u{01}":
            adjustNumberOnLine(by: consumeCount(), in: buffer)
            return true
        case "\u{18}":
            adjustNumberOnLine(by: -consumeCount(), in: buffer)
            return true
        case "\u{04}":
            scrollByLines(halfVisibleLineCount(in: buffer), in: buffer)
            return true
        case "\u{15}":
            scrollByLines(-halfVisibleLineCount(in: buffer), in: buffer)
            return true
        case "\u{06}":
            scrollByLines(visibleLineSpan(in: buffer), in: buffer)
            return true
        case "\u{02}":
            scrollByLines(-visibleLineSpan(in: buffer), in: buffer)
            return true
        case "\u{05}", "\u{19}":
            // Ctrl+E / Ctrl+Y — viewport-only scroll; engine has no viewport to mutate
            // beyond what the text view tracks. We consume and rely on the cursor
            // manager / text view to honour the visible-range contract.
            return true
        default:
            return nil
        }
    }

    private func halfVisibleLineCount(in buffer: VimTextBuffer) -> Int {
        let (first, last) = buffer.visibleLineRange()
        return max(1, (last - first + 1) / 2)
    }

    private func visibleLineSpan(in buffer: VimTextBuffer) -> Int {
        let (first, last) = buffer.visibleLineRange()
        return max(1, last - first + 1)
    }

    private func scrollByLines(_ delta: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let (currentLine, col) = buffer.lineAndColumn(forOffset: pos)
        let targetLine = max(0, min(buffer.lineCount - 1, currentLine + delta))
        let offset = buffer.offset(forLine: targetLine, column: col)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
        goalColumn = nil
    }

    // MARK: - Number Adjust (Ctrl-A / Ctrl-X)

    private func adjustNumberOnLine(by delta: Int, in buffer: VimTextBuffer) {
        guard delta != 0 else { return }
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        guard let match = findNumber(from: pos, lineStart: lineRange.location, contentEnd: contentEnd, in: buffer) else {
            return
        }
        let replacement = formatNumber(match.value + delta, hex: match.isHex, hexUppercase: match.hexUppercase)
        let range = NSRange(location: match.start, length: match.end - match.start)
        buffer.replaceCharacters(in: range, with: replacement)
        let newEnd = match.start + (replacement as NSString).length
        buffer.setSelectedRange(NSRange(location: max(match.start, newEnd - 1), length: 0))
    }

    private struct NumberMatch {
        var start: Int
        var end: Int
        var value: Int
        var isHex: Bool
        var hexUppercase: Bool
    }

    private func findNumber(from cursor: Int, lineStart: Int, contentEnd: Int, in buffer: VimTextBuffer) -> NumberMatch? {
        guard contentEnd > lineStart else { return nil }
        var scan = max(cursor, lineStart)
        while scan < contentEnd && !isDigitChar(buffer.character(at: scan)) {
            scan += 1
        }
        guard scan < contentEnd else { return nil }
        var start = scan
        // Detect hex prefix: walk back to see if start-2 is "0x"
        if start >= lineStart + 2
            && buffer.character(at: start - 2) == 0x30
            && (buffer.character(at: start - 1) == 0x78 || buffer.character(at: start - 1) == 0x58) {
            start -= 2
        }
        var end = scan
        let isHex = start + 1 < contentEnd
            && buffer.character(at: start) == 0x30
            && (buffer.character(at: start + 1) == 0x78 || buffer.character(at: start + 1) == 0x58)
        var hexUppercase = false
        if isHex {
            hexUppercase = buffer.character(at: start + 1) == 0x58
            end = start + 2
            while end < contentEnd && isHexDigitChar(buffer.character(at: end)) {
                end += 1
            }
            guard end > start + 2 else { return nil }
        } else {
            while end < contentEnd && isDigitChar(buffer.character(at: end)) {
                end += 1
            }
            if start > lineStart && buffer.character(at: start - 1) == 0x2D {
                start -= 1
            }
        }
        let text = buffer.string(in: NSRange(location: start, length: end - start))
        guard let value = parseNumberLiteral(text) else { return nil }
        return NumberMatch(start: start, end: end, value: value, isHex: isHex, hexUppercase: hexUppercase)
    }

    private func parseNumberLiteral(_ text: String) -> Int? {
        if text.hasPrefix("-") || text.hasPrefix("+") {
            return Int(text)
        }
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            return Int(text.dropFirst(2), radix: 16)
        }
        return Int(text)
    }

    private func formatNumber(_ value: Int, hex: Bool, hexUppercase: Bool) -> String {
        if hex {
            let body = String(value, radix: 16, uppercase: hexUppercase)
            return (hexUppercase ? "0X" : "0x") + body
        }
        return String(value)
    }

    private func isDigitChar(_ ch: unichar) -> Bool { ch >= 0x30 && ch <= 0x39 }

    private func isHexDigitChar(_ ch: unichar) -> Bool {
        isDigitChar(ch) || (ch >= 0x41 && ch <= 0x46) || (ch >= 0x61 && ch <= 0x66)
    }

    // MARK: - Text Objects (iw, aw, i", a", i(, a(, ...)

    /// Resolve a text object key (w, W, ", ', (, ), {, }, [, ], <, >, t, p, b, B)
    /// into a range and then apply the pending operator or update the visual selection.
    private func executeTextObject(_ key: Character, around: Bool, in buffer: VimTextBuffer) -> Bool {
        let pos = buffer.selectedRange().location
        guard let range = textObjectRange(key: key, around: around, cursor: pos, in: buffer) else {
            pendingOperator = nil
            return true
        }
        if mode.isVisual {
            buffer.setSelectedRange(range)
            return true
        }
        if let op = pendingOperator {
            executeOperatorOnRange(op, range: range, linewise: false, in: buffer)
            pendingOperator = nil
        }
        return true
    }

    private func textObjectRange(key: Character, around: Bool, cursor: Int, in buffer: VimTextBuffer) -> NSRange? {
        switch key {
        case "w": return wordObject(at: cursor, bigWord: false, around: around, in: buffer)
        case "W": return wordObject(at: cursor, bigWord: true, around: around, in: buffer)
        case "\"", "'", "`":
            return quotedObject(at: cursor, delimiter: key, around: around, in: buffer)
        case "(", ")", "b": return bracketedObject(at: cursor, open: "(", close: ")", around: around, in: buffer)
        case "{", "}", "B": return bracketedObject(at: cursor, open: "{", close: "}", around: around, in: buffer)
        case "[", "]": return bracketedObject(at: cursor, open: "[", close: "]", around: around, in: buffer)
        case "<", ">": return bracketedObject(at: cursor, open: "<", close: ">", around: around, in: buffer)
        case "t": return tagObject(at: cursor, around: around, in: buffer)
        case "p": return paragraphObject(at: cursor, around: around, in: buffer)
        default: return nil
        }
    }

    private func wordObject(at cursor: Int, bigWord: Bool, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        guard buffer.length > 0 else { return nil }
        let pos = min(max(0, cursor), buffer.length - 1)
        let classifier: (unichar) -> Int = { ch in
            if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D { return 0 }
            if bigWord { return 1 }
            if ch == 0x5F { return 1 }
            if let scalar = UnicodeScalar(ch), CharacterSet.alphanumerics.contains(scalar) { return 1 }
            return 2
        }
        let startClass = classifier(buffer.character(at: pos))
        var start = pos
        while start > 0 && classifier(buffer.character(at: start - 1)) == startClass { start -= 1 }
        var end = pos
        while end < buffer.length - 1 && classifier(buffer.character(at: end + 1)) == startClass { end += 1 }
        var rangeEnd = end + 1
        if around {
            // Include trailing whitespace (or leading if no trailing).
            var trail = rangeEnd
            while trail < buffer.length {
                let ch = buffer.character(at: trail)
                if ch == 0x20 || ch == 0x09 { trail += 1 } else { break }
            }
            if trail > rangeEnd {
                rangeEnd = trail
            } else {
                while start > 0 {
                    let ch = buffer.character(at: start - 1)
                    if ch == 0x20 || ch == 0x09 { start -= 1 } else { break }
                }
            }
        }
        return NSRange(location: start, length: rangeEnd - start)
    }

    private func quotedObject(at cursor: Int, delimiter: Character, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        guard let scalar = delimiter.unicodeScalars.first else { return nil }
        let quote = unichar(scalar.value)
        let lineRange = buffer.lineRange(forOffset: cursor)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        var open: Int?
        var close: Int?
        var scan = lineRange.location
        while scan < contentEnd {
            if buffer.character(at: scan) == quote {
                if let o = open {
                    if cursor >= o && cursor <= scan {
                        close = scan
                        break
                    }
                    open = scan
                } else {
                    open = scan
                }
            }
            scan += 1
        }
        if close == nil, let o = open, cursor >= o {
            scan = o + 1
            while scan < contentEnd {
                if buffer.character(at: scan) == quote {
                    close = scan
                    break
                }
                scan += 1
            }
        }
        guard let o = open, let c = close, c > o else { return nil }
        if around {
            // Include one surrounding whitespace char (trailing preferred, else leading).
            var rangeEnd = c + 1
            var rangeStart = o
            while rangeEnd < contentEnd {
                let ch = buffer.character(at: rangeEnd)
                if ch == 0x20 || ch == 0x09 { rangeEnd += 1 } else { break }
            }
            if rangeEnd == c + 1 {
                while rangeStart > lineRange.location {
                    let ch = buffer.character(at: rangeStart - 1)
                    if ch == 0x20 || ch == 0x09 { rangeStart -= 1 } else { break }
                }
            }
            return NSRange(location: rangeStart, length: rangeEnd - rangeStart)
        }
        return NSRange(location: o + 1, length: c - o - 1)
    }

    private func bracketedObject(at cursor: Int, open: Character, close: Character, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        guard let openScalar = open.unicodeScalars.first,
              let closeScalar = close.unicodeScalars.first else { return nil }
        let openCh = unichar(openScalar.value)
        let closeCh = unichar(closeScalar.value)
        // Find enclosing open.
        var openPos: Int?
        var depth = 0
        if cursor < buffer.length && buffer.character(at: cursor) == openCh {
            openPos = cursor
        } else if cursor < buffer.length && buffer.character(at: cursor) == closeCh {
            // Walk back to matching open.
            var d = 1
            var i = cursor - 1
            while i >= 0 {
                let ch = buffer.character(at: i)
                if ch == closeCh { d += 1 }
                else if ch == openCh {
                    d -= 1
                    if d == 0 { openPos = i; break }
                }
                i -= 1
            }
        } else {
            var i = cursor - 1
            depth = 0
            while i >= 0 {
                let ch = buffer.character(at: i)
                if ch == closeCh { depth += 1 }
                else if ch == openCh {
                    if depth == 0 { openPos = i; break }
                    depth -= 1
                }
                i -= 1
            }
        }
        guard let o = openPos else { return nil }
        // Find matching close.
        var closePos: Int?
        var d = 1
        var i = o + 1
        while i < buffer.length {
            let ch = buffer.character(at: i)
            if ch == openCh { d += 1 }
            else if ch == closeCh {
                d -= 1
                if d == 0 { closePos = i; break }
            }
            i += 1
        }
        guard let c = closePos else { return nil }
        if around { return NSRange(location: o, length: c - o + 1) }
        guard c > o + 1 else { return NSRange(location: o + 1, length: 0) }
        return NSRange(location: o + 1, length: c - o - 1)
    }

    private func tagObject(at cursor: Int, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        // Scan backward for the nearest '<tagname>' before cursor and forward for the
        // matching '</tagname>'. Simplistic — doesn't handle attributes or nesting.
        var openStart: Int?
        var openEnd: Int?
        var i = cursor
        while i >= 0 {
            if buffer.character(at: i) == 0x3C { // '<'
                openStart = i
                var j = i + 1
                while j < buffer.length && buffer.character(at: j) != 0x3E { j += 1 }
                if j < buffer.length {
                    openEnd = j
                }
                break
            }
            i -= 1
        }
        guard let os = openStart, let oe = openEnd else { return nil }
        let tagNameStart = os + 1
        let tagName = buffer.string(in: NSRange(location: tagNameStart, length: oe - tagNameStart))
        guard !tagName.hasPrefix("/") else { return nil }
        // Find matching close tag from oe.
        let closeMarker = "</" + tagName + ">"
        let after = buffer.string(in: NSRange(location: oe + 1, length: buffer.length - oe - 1)) as NSString
        let foundRange = after.range(of: closeMarker)
        guard foundRange.location != NSNotFound else { return nil }
        let closeStart = oe + 1 + foundRange.location
        let closeEnd = closeStart + foundRange.length
        if around { return NSRange(location: os, length: closeEnd - os) }
        return NSRange(location: oe + 1, length: closeStart - oe - 1)
    }

    private func paragraphObject(at cursor: Int, around: Bool, in buffer: VimTextBuffer) -> NSRange? {
        let (currentLine, _) = buffer.lineAndColumn(forOffset: cursor)
        var startLine = currentLine
        while startLine > 0 && !lineIsBlank(startLine - 1, in: buffer) {
            startLine -= 1
        }
        var endLine = currentLine
        while endLine < buffer.lineCount - 1 && !lineIsBlank(endLine + 1, in: buffer) {
            endLine += 1
        }
        let start = buffer.offset(forLine: startLine, column: 0)
        // For ip, end at the start of the line after the paragraph's last content line
        // *minus the trailing newline* — so deleting it leaves the blank-line separator
        // intact. For ap, also consume the trailing blank line.
        let lastContentLineRange = buffer.lineRange(forOffset: buffer.offset(forLine: endLine, column: 0))
        var end = lastContentLineRange.location + lastContentLineRange.length
        if !around && end > start {
            // Drop the trailing newline so the paragraph separator (blank line) survives.
            end -= 1
        }
        if around {
            var trailing = endLine
            while trailing < buffer.lineCount - 1 && lineIsBlank(trailing + 1, in: buffer) {
                trailing += 1
            }
            if trailing > endLine {
                let trailingRange = buffer.lineRange(forOffset: buffer.offset(forLine: trailing, column: 0))
                end = trailingRange.location + trailingRange.length
            }
        }
        return NSRange(location: start, length: end - start)
    }

    private func lineIsBlank(_ line: Int, in buffer: VimTextBuffer) -> Bool {
        let offset = buffer.offset(forLine: line, column: 0)
        let lineRange = buffer.lineRange(forOffset: offset)
        let lineEnd = lineRange.location + lineRange.length
        if lineEnd <= lineRange.location { return true }
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        return contentEnd == lineRange.location
    }

    // MARK: - Search (/, ?, n, N, *, #)

    private func runSearch(pattern: String, forward: Bool) {
        guard !pattern.isEmpty, let buffer else { return }
        lastSearchPattern = pattern
        lastSearchForward = forward
        let origin = buffer.selectedRange().location
        if let target = findPattern(pattern, from: origin, forward: forward, wholeWord: false, in: buffer) {
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
    }

    private func searchNext(in buffer: VimTextBuffer, reverseDirection: Bool) {
        guard let pattern = lastSearchPattern else { return }
        let forward = reverseDirection ? !lastSearchForward : lastSearchForward
        let origin = buffer.selectedRange().location
        if let target = findPattern(pattern, from: origin, forward: forward, wholeWord: false, in: buffer) {
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
    }

    private func searchWordUnderCursor(forward: Bool, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos < buffer.length else { return }
        var start = pos
        while start > 0 && isWordChar(buffer.character(at: start - 1)) { start -= 1 }
        var end = pos
        while end < buffer.length && isWordChar(buffer.character(at: end)) { end += 1 }
        guard end > start else { return }
        let word = buffer.string(in: NSRange(location: start, length: end - start))
        lastSearchPattern = word
        lastSearchForward = forward
        let origin = pos
        if let target = findPattern(word, from: origin, forward: forward, wholeWord: true, in: buffer) {
            buffer.setSelectedRange(NSRange(location: target, length: 0))
            lastJumpOrigin = origin
        }
    }

    /// Locate the next occurrence of `pattern` in `buffer` starting from `origin`, in
    /// the given direction. Wraps around. When `wholeWord` is true the match must be
    /// surrounded by non-word characters or buffer boundaries.
    private func findPattern(_ pattern: String, from origin: Int, forward: Bool, wholeWord: Bool, in buffer: VimTextBuffer) -> Int? {
        let nsBuffer = NSMutableString()
        for i in 0..<buffer.length { nsBuffer.appendFormat("%C", buffer.character(at: i)) }
        let total = nsBuffer.length
        guard total > 0 else { return nil }
        let needle = pattern as NSString
        guard needle.length > 0 else { return nil }
        let matches: (Int) -> Bool = { idx in
            guard idx + needle.length <= total else { return false }
            let candidate = nsBuffer.substring(with: NSRange(location: idx, length: needle.length))
            guard candidate == pattern else { return false }
            if !wholeWord { return true }
            let beforeOk = idx == 0 || !self.isWordChar(nsBuffer.character(at: idx - 1))
            let afterIdx = idx + needle.length
            let afterOk = afterIdx >= total || !self.isWordChar(nsBuffer.character(at: afterIdx))
            return beforeOk && afterOk
        }

        if forward {
            var i = origin + 1
            while i < total {
                if matches(i) { return i }
                i += 1
            }
            i = 0
            while i < origin {
                if matches(i) { return i }
                i += 1
            }
            if matches(origin) { return origin }
        } else {
            var i = origin - 1
            while i >= 0 {
                if matches(i) { return i }
                i -= 1
            }
            i = total - 1
            while i > origin {
                if matches(i) { return i }
                i -= 1
            }
            if matches(origin) { return origin }
        }
        return nil
    }

    private func isWordChar(_ ch: unichar) -> Bool {
        if ch == 0x5F { return true }
        guard let scalar = UnicodeScalar(ch) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Macros (q, @, @@)

    private func handleMacroTarget(kind: MacroPendingKind, register: Character) {
        switch kind {
        case .recordTarget:
            macroRecording = register
            macroBuffers[register] = []
        case .replayTarget:
            let target: Character
            if register == "@" { target = lastInvokedMacro ?? Character("\0") } else { target = register }
            guard let keys = macroBuffers[target], !keys.isEmpty else {
                pendingMacroCount = 1
                return
            }
            lastInvokedMacro = target
            let count = max(1, pendingMacroCount)
            pendingMacroCount = 1
            for _ in 0..<count { replayMacro(keys: keys) }
        }
    }

    private func replayMacro(keys: [(Character, Bool)]) {
        // Cap recursion to avoid runaway self-invoking macros.
        guard macroPlaybackDepth < 50 else { return }
        macroPlaybackDepth += 1
        defer { macroPlaybackDepth -= 1 }
        let saved = macroRecording
        macroRecording = nil
        for (char, shift) in keys {
            _ = process(char, shift: shift)
        }
        macroRecording = saved
    }

    // MARK: - Sentence / Paragraph Motions

    /// `)` — advance to the start of the next sentence on this line, then later lines.
    private func sentenceForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = nextSentenceStart(after: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func sentenceBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = previousSentenceStart(before: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func nextSentenceStart(after origin: Int, in buffer: VimTextBuffer) -> Int {
        var i = origin
        while i < buffer.length - 1 {
            let ch = buffer.character(at: i)
            let nextCh = buffer.character(at: i + 1)
            let endsSentence = ch == 0x2E || ch == 0x21 || ch == 0x3F // . ! ?
            let followedByBoundary = nextCh == 0x20 || nextCh == 0x09 || nextCh == 0x0A
            if endsSentence && followedByBoundary {
                var j = i + 1
                while j < buffer.length {
                    let cj = buffer.character(at: j)
                    if cj == 0x20 || cj == 0x09 || cj == 0x0A { j += 1 } else { break }
                }
                if j < buffer.length { return j }
            }
            i += 1
        }
        return buffer.length > 0 ? buffer.length - 1 : 0
    }

    private func previousSentenceStart(before origin: Int, in buffer: VimTextBuffer) -> Int {
        var i = origin - 2
        while i >= 0 {
            let ch = buffer.character(at: i)
            if i + 1 < buffer.length {
                let nextCh = buffer.character(at: i + 1)
                let endsSentence = ch == 0x2E || ch == 0x21 || ch == 0x3F
                let followedByBoundary = nextCh == 0x20 || nextCh == 0x09 || nextCh == 0x0A
                if endsSentence && followedByBoundary {
                    var j = i + 1
                    while j < buffer.length {
                        let cj = buffer.character(at: j)
                        if cj == 0x20 || cj == 0x09 || cj == 0x0A { j += 1 } else { break }
                    }
                    if j < origin { return j }
                }
            }
            i -= 1
        }
        return 0
    }

    private func paragraphForward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = nextParagraphBoundary(after: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func paragraphBackward(_ count: Int, in buffer: VimTextBuffer) {
        var pos = buffer.selectedRange().location
        for _ in 0..<count {
            pos = previousParagraphBoundary(before: pos, in: buffer)
        }
        buffer.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func nextParagraphBoundary(after origin: Int, in buffer: VimTextBuffer) -> Int {
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine + 1
        let lineCount = buffer.lineCount
        while line < lineCount {
            if lineIsBlank(line, in: buffer) {
                return buffer.offset(forLine: line, column: 0)
            }
            line += 1
        }
        return buffer.length > 0 ? buffer.length - 1 : 0
    }

    private func previousParagraphBoundary(before origin: Int, in buffer: VimTextBuffer) -> Int {
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine - 1
        while line > 0 {
            if lineIsBlank(line, in: buffer) {
                return buffer.offset(forLine: line, column: 0)
            }
            line -= 1
        }
        return 0
    }

    private func sectionForward(in buffer: VimTextBuffer) {
        let origin = buffer.selectedRange().location
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine + 1
        while line < buffer.lineCount {
            let off = buffer.offset(forLine: line, column: 0)
            if off < buffer.length && buffer.character(at: off) == 0x7B {
                buffer.setSelectedRange(NSRange(location: off, length: 0))
                return
            }
            line += 1
        }
        buffer.setSelectedRange(NSRange(location: max(0, buffer.length - 1), length: 0))
    }

    private func sectionBackward(in buffer: VimTextBuffer) {
        let origin = buffer.selectedRange().location
        let (originLine, _) = buffer.lineAndColumn(forOffset: origin)
        var line = originLine - 1
        while line >= 0 {
            let off = buffer.offset(forLine: line, column: 0)
            if off < buffer.length && buffer.character(at: off) == 0x7B {
                buffer.setSelectedRange(NSRange(location: off, length: 0))
                return
            }
            line -= 1
        }
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
    }
}
