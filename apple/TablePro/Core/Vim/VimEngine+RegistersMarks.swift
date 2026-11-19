//
//  VimEngine+RegistersMarks.swift
//  TablePro
//

import Foundation

// What Vim remembers about one document, by offset into its text.
struct VimDocumentMarks {
    var marks: [Character: Int] = [:]
    var lastVisualStart: Int?
    var lastVisualEnd: Int?
    var lastVisualLinewise = false
    var lastJumpOrigin: Int?
    var lastInsertOffset: Int?

    var isEmpty: Bool {
        marks.isEmpty && lastVisualStart == nil && lastVisualEnd == nil && lastJumpOrigin == nil && lastInsertOffset == nil
    }
}

extension VimEngine {
    var documentMarks: VimDocumentMarks {
        VimDocumentMarks(
            marks: marks,
            lastVisualStart: lastVisualStart,
            lastVisualEnd: lastVisualEnd,
            lastVisualLinewise: lastVisualLinewise,
            lastJumpOrigin: lastJumpOrigin,
            lastInsertOffset: lastInsertOffset
        )
    }

    func restoreDocumentMarks(_ saved: VimDocumentMarks) {
        marks = saved.marks
        lastVisualStart = saved.lastVisualStart
        lastVisualEnd = saved.lastVisualEnd
        lastVisualLinewise = saved.lastVisualLinewise
        lastJumpOrigin = saved.lastJumpOrigin
        lastInsertOffset = saved.lastInsertOffset
    }

    func writeToActiveRegister(text: String, linewise: Bool, asDelete: Bool) {
        if selectedRegister == "_" {
            selectedRegister = nil
            return
        }
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
        if let name = selectedRegister {
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

    func activePasteRegister() -> VimRegister {
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

    // `'` goes to the first non-blank of the mark's line and takes whole lines after an operator; `` ` `` goes to
    // the mark itself. An unset mark ends the command.
    func jumpToMark(_ name: Character, exact: Bool, in buffer: VimTextBuffer) {
        let offset: Int?
        switch name {
        case "'", "`": offset = lastJumpOrigin
        case "<": offset = lastVisualStart
        case ">": offset = lastVisualEnd
        default: offset = marks[name]
        }
        guard let offset else {
            applyMotion(to: nil, kind: .exclusive, in: buffer)
            return
        }
        let clamped = min(max(0, offset), buffer.length)
        if exact {
            applyMotion(to: clamped, kind: .exclusive, jump: true, in: buffer)
        } else {
            let lineStart = buffer.lineRange(forOffset: clamped).location
            applyMotion(to: firstNonBlankOffset(from: lineStart, in: buffer), kind: .linewise, jump: true, in: buffer)
        }
    }

    func recordVisualSelection(linewise: Bool, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        guard sel.length > 0 else { return }
        lastVisualStart = sel.location
        lastVisualEnd = characterStart(at: NSMaxRange(sel) - 1, in: buffer)
        lastVisualLinewise = linewise
    }

    func reselectLastVisual(in buffer: VimTextBuffer) {
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
            setMode(.visual(linewise: true))
        } else {
            let selectionEnd = clampedEnd < buffer.length ? characterEnd(at: clampedEnd, in: buffer) : clampedEnd
            buffer.setSelectedRange(NSRange(location: clampedStart, length: selectionEnd - clampedStart))
            setMode(.visual(linewise: false))
        }
    }

    // Called before every edit, typed, pasted, undone or the engine's own. A mark keeps its line and column, as Vim's
    // do (`:help mark-motions`): lines added or removed before it move it, a join carries it with its text, and
    // removing its whole line removes a named mark and moves the others to where the lines were.
    func textWillChange(in range: NSRange, with replacement: String) {
        guard let buffer, !marks.isEmpty || lastJumpOrigin != nil || lastInsertOffset != nil
            || lastVisualStart != nil || lastVisualEnd != nil else { return }
        let change = VimMarkChange(range: range, replacement: replacement, in: buffer)
        marks = marks.compactMapValues { change.map($0, removable: true, in: buffer) }
        lastJumpOrigin = lastJumpOrigin.flatMap { change.map($0, removable: false, in: buffer) }
        lastInsertOffset = lastInsertOffset.flatMap { change.map($0, removable: false, in: buffer) }
        lastVisualStart = lastVisualStart.flatMap { change.map($0, removable: false, in: buffer) }
        lastVisualEnd = lastVisualEnd.flatMap { change.map($0, removable: false, in: buffer) }
    }
}

// One edit, read from the text before it, as Vim's line-based mark adjustment sees it.
@MainActor
struct VimMarkChange {
    private let location: Int
    private let end: Int
    private let delta: Int
    private let removesLineBreak: Bool
    // Whole lines removed, inserted or replaced at a line start, as `dd`, `p` and `O` and their undo make.
    private let isLinewise: Bool
    private let firstLineStart: Int
    private let endLineEnd: Int
    // Where the line holding the edit's start ends once the edit is in.
    private let firstLineContentEnd: Int

    init(range: NSRange, replacement: String, in buffer: VimTextBuffer) {
        let inserted = replacement as NSString
        location = range.location
        end = NSMaxRange(range)
        delta = inserted.length - range.length
        var removedBreak = false
        var scan = range.location
        while scan < end, !removedBreak {
            let ch = buffer.character(at: scan)
            removedBreak = ch == 0x0A || ch == 0x0D
            scan += 1
        }
        removesLineBreak = removedBreak
        let firstLine = buffer.lineRange(forOffset: range.location)
        firstLineStart = firstLine.location
        let removedEndsWithBreak = range.length == 0 || buffer.character(at: end - 1) == 0x0A
        let insertedEndsWithBreak = inserted.length == 0 || inserted.character(at: inserted.length - 1) == 0x0A
        isLinewise = range.location == firstLine.location && removedEndsWithBreak && insertedEndsWithBreak
        let endLine = buffer.lineRange(forOffset: end)
        endLineEnd = NSMaxRange(endLine)
        let insertedBreak = inserted.rangeOfCharacter(from: .newlines)
        if insertedBreak.location != NSNotFound {
            firstLineContentEnd = range.location + insertedBreak.location
        } else {
            let endLineHasBreak = endLineEnd > endLine.location && buffer.character(at: endLineEnd - 1) == 0x0A
            firstLineContentEnd = (endLineHasBreak ? endLineEnd - 1 : endLineEnd) + delta
        }
    }

    func map(_ offset: Int, removable: Bool, in buffer: VimTextBuffer) -> Int? {
        if offset < location { return offset }
        if isLinewise {
            if offset >= end { return offset + delta }
            return removable ? nil : location
        }
        if offset >= end {
            if offset >= endLineEnd || removesLineBreak { return offset + delta }
            return keepingColumn(offset)
        }
        if removesLineBreak {
            let line = buffer.lineRange(forOffset: offset)
            if line.location > firstLineStart {
                if NSMaxRange(line) <= end { return removable ? nil : location }
                return end + delta
            }
        }
        return keepingColumn(offset)
    }

    // The line keeps its start, so the offset keeps the column, up to the line's new last character.
    private func keepingColumn(_ offset: Int) -> Int {
        min(offset, max(firstLineStart, firstLineContentEnd - 1))
    }
}
