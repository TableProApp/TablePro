//
//  VimEngine.swift
//  TablePro
//

import Foundation
import os

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

struct VimFindCharRequest {
    let forward: Bool
    let till: Bool
}

struct VimLastFindChar {
    let char: Character
    let forward: Bool
    let till: Bool
}

enum VimDotKind {
    case deleteCharForward(count: Int)
    case deleteCharBackward(count: Int)
    case operatorWithMotion(op: VimOperator, motion: Character, shift: Bool, count: Int)
    case operatorDoubled(op: VimOperator, count: Int)
    case toggleCase(count: Int)
    case joinLines(withSpace: Bool, count: Int)
    case replaceChar(char: Character, count: Int)
}

// `:help exclusive`, `:help inclusive`, `:help linewise`.
enum VimMotionKind { case exclusive, inclusive, linewise }

enum VimMacroPendingKind { case recordTarget, replayTarget }
enum VimBracketPending { case openBracket, closeBracket }
enum VimScreenPosition { case top, middle, bottom }

struct VimReplaceModeEdit {
    let offset: Int
    let original: String?
    let insertedLength: Int
}

@MainActor
final class VimEngine {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "VimEngine")

    private(set) var mode: VimMode = .normal {
        didSet {
            if oldValue != mode {
                onModeChange?(mode)
            }
        }
    }

    var cursorOffset: Int = 0

    var register = VimRegister()
    var pendingOperator: VimOperator?
    var countPrefix: Int = 0
    var operatorCount: Int = 0
    var goalColumn: Int?
    var pendingG: Bool = false
    var pendingFindChar: VimFindCharRequest?
    var pendingReplaceChar: Bool = false
    var pendingMarkSet: Bool = false
    var pendingMarkJumpExact: Bool?
    var pendingRegisterSelect: Bool = false
    var pendingReplaceCharForVisual: Bool = false
    var pendingZ: Bool = false
    var pendingTextObject: Bool = false
    var pendingTextObjectAround: Bool = false
    var pendingMacroTarget: VimMacroPendingKind?
    var pendingMacroCount: Int = 1
    var pendingBracket: VimBracketPending?
    var selectedRegister: Character?
    var lastFindChar: VimLastFindChar?
    var lastDotKind: VimDotKind?
    var marks: [Character: Int] = [:]
    var namedRegisters: [Character: VimRegister] = [:]
    var numberedRegisters: [VimRegister] = Array(repeating: VimRegister(), count: 10)
    var editsOnCurrentLine: Int = 0
    var lastEditedLine: Int?
    var lastJumpOrigin: Int?
    var lastVisualStart: Int?
    var lastVisualEnd: Int?
    var lastVisualLinewise: Bool = false
    var lastSearchPattern: String?
    var lastSearchForward: Bool = true
    var macroRecording: Character?
    var macroBuffers: [Character: [(Character, Bool)]] = [:]
    var lastInvokedMacro: Character?
    var macroPlaybackDepth: Int = 0
    var visualAnchor: Int = 0
    var lastInsertOffset: Int?
    var replaceModeEdits: [VimReplaceModeEdit] = []
    var searchCount: Int = 1
    // The column each named mark was set at, kept past the end of a line that shrinks, as Vim keeps it.
    var markColumns: [Character: Int] = [:]
    // Recent edits with the positions from before each, so undoing one puts them back.
    var editJournal: [VimEditRecord] = []

    var buffer: VimTextBuffer?

    var onModeChange: ((VimMode) -> Void)?
    var onCommand: ((String) -> Void)?

    init(buffer: VimTextBuffer) {
        self.buffer = buffer
    }

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
            // A register named in Visual mode belongs to the command that ends it, used or not.
            if !mode.isVisual { selectedRegister = nil }
        case .commandLine(let commandBuffer):
            consumed = processCommandLine(char, buffer: commandBuffer)
        }
        if let target = recordingTarget, macroRecording == target {
            macroBuffers[target, default: []].append((char, shift))
        }
        if !mode.isVisual, let buffer {
            cursorOffset = buffer.selectedRange().location
        }
        return consumed
    }

    func invalidateLineCache() {
        buffer?.invalidateLineCache()
    }

    // Offsets into the old text mean nothing in the new one. Registers, macros and the last search carry over, as
    // they do between buffers in Vim.
    func documentDidReplace() {
        restoreDocumentMarks(VimDocumentMarks())
        replaceModeEdits.removeAll()
        editsOnCurrentLine = 0
        lastEditedLine = nil
    }

    func reset() {
        cancelPendingCommand()
        mode = .normal
    }

    // Escape, leaving the command line or a motion that cannot move ends the whole command, so no part of it
    // reaches the next key.
    func cancelPendingCommand() {
        pendingOperator = nil
        countPrefix = 0
        operatorCount = 0
        pendingG = false
        pendingFindChar = nil
        pendingReplaceChar = false
        pendingMarkSet = false
        pendingMarkJumpExact = nil
        pendingRegisterSelect = false
        selectedRegister = nil
        pendingReplaceCharForVisual = false
        pendingZ = false
        pendingTextObject = false
        pendingMacroTarget = nil
        pendingMacroCount = 1
        pendingBracket = nil
        searchCount = 1
    }

    // A key that still waits for the rest of its command, not counting a count or a register already typed.
    var hasPendingCommand: Bool {
        pendingOperator != nil || pendingG || pendingFindChar != nil || pendingReplaceChar || pendingMarkSet
            || pendingMarkJumpExact != nil || pendingRegisterSelect || pendingZ || pendingTextObject
            || pendingMacroTarget != nil || pendingBracket != nil
    }

    func setMode(_ newMode: VimMode) {
        mode = newMode
    }

    func consumeCount() -> Int {
        let motionCount = countPrefix > 0 ? countPrefix : 1
        let opCount = operatorCount > 0 ? operatorCount : 1
        let total = motionCount * opCount
        countPrefix = 0
        operatorCount = 0
        return total
    }
}
