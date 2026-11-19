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
    var markColumns: [Character: Int] = [:]
    var markUndoRecords: [VimMarkUndoRecord] = []

    var isEmpty: Bool {
        marks.isEmpty && lastVisualStart == nil && lastVisualEnd == nil && lastJumpOrigin == nil && lastInsertOffset == nil
            && markUndoRecords.isEmpty
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
            lastInsertOffset: lastInsertOffset,
            markColumns: markColumns,
            markUndoRecords: markUndoRecords
        )
    }

    func restoreDocumentMarks(_ saved: VimDocumentMarks) {
        marks = saved.marks
        markColumns = saved.markColumns
        markUndoRecords = saved.markUndoRecords
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
        var clamped = min(max(0, offset), buffer.length)
        if let column = markColumns[name] {
            let lineStart = buffer.lineRange(forOffset: clamped).location
            let lastCharacter = max(lineStart, contentEnd(ofLineAt: clamped, in: buffer) - 1)
            clamped = min(lineStart + column, lastCharacter)
        }
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

    func setMark(_ name: Character, at offset: Int, in buffer: VimTextBuffer) {
        marks[name] = offset
        markColumns[name] = offset - buffer.lineRange(forOffset: offset).location
    }

    // Called before every edit, typed, pasted, undone or the engine's own. A mark keeps its line and column, as Vim's
    // do (`:help mark-motions`): lines added or removed before it move it, a join carries it with its text, and
    // removing its whole line removes a named mark. An edit that exactly reverses an earlier one, as undo does, puts
    // back the marks that edit removed or carried onto another line.
    func textWillChange(in range: NSRange, with replacement: String) {
        guard let buffer, !marks.isEmpty || !markUndoRecords.isEmpty || lastJumpOrigin != nil
            || lastInsertOffset != nil || lastVisualStart != nil || lastVisualEnd != nil else { return }
        var restored: VimMarkUndoRecord?
        if let index = markUndoRecords.lastIndex(where: { $0.isReversed(by: range, replacement: replacement) }) {
            restored = markUndoRecords.remove(at: index)
        }
        let change = VimMarkChange(range: range, replacement: replacement, in: buffer)
        var displaced: [Character: VimSavedMark] = [:]
        for (name, offset) in marks {
            let mapped = change.map(offset, removable: true, in: buffer)
            if mapped?.keepsColumn != true {
                let column = markColumns[name] ?? offset - buffer.lineRange(forOffset: offset).location
                displaced[name] = VimSavedMark(relative: offset - range.location, column: column)
                markColumns[name] = nil
            }
            marks[name] = mapped?.offset
        }
        markUndoRecords = markUndoRecords.map { record in
            var moved = record
            moved.location = change.map(record.location, removable: false, in: buffer)?.offset ?? record.location
            return moved
        }
        if !displaced.isEmpty {
            markUndoRecords.append(VimMarkUndoRecord(
                location: range.location,
                removedText: buffer.string(in: range),
                insertedLength: (replacement as NSString).length,
                marks: displaced
            ))
            if markUndoRecords.count > 20 { markUndoRecords.removeFirst() }
        }
        if let restored {
            for (name, saved) in restored.marks {
                marks[name] = restored.location + saved.relative
                markColumns[name] = saved.column
            }
        }
        lastJumpOrigin = lastJumpOrigin.flatMap { change.map($0, removable: false, in: buffer)?.offset }
        lastInsertOffset = lastInsertOffset.flatMap {
            change.map($0, removable: false, isInsertionPoint: true, in: buffer)?.offset
        }
        lastVisualStart = lastVisualStart.flatMap { change.map($0, removable: false, in: buffer)?.offset }
        lastVisualEnd = lastVisualEnd.flatMap { change.map($0, removable: false, in: buffer)?.offset }
    }
}

struct VimSavedMark {
    let relative: Int
    let column: Int
}

// The marks one edit removed or carried onto another line, with where they were relative to the edit's start.
struct VimMarkUndoRecord {
    var location: Int
    let removedText: String
    let insertedLength: Int
    let marks: [Character: VimSavedMark]

    func isReversed(by range: NSRange, replacement: String) -> Bool {
        range.location == location && range.length == insertedLength && replacement == removedText
    }
}

// One edit, read from the text before it, as Vim's line-based mark adjustment sees it.
@MainActor
struct VimMarkChange {
    private let location: Int
    private let end: Int
    private let delta: Int
    private let removed: [unichar]
    private let inserted: [unichar]
    private let insertedBreaks: Int
    private let removesLineBreak: Bool
    // Whole lines removed or inserted at a line start, as `dd`, `p` and `O` and their undo make.
    private let isLinewise: Bool
    // As many line breaks go in as come out, so every line keeps its marks, as a shift or a case change does.
    private let keepsLines: Bool
    private let firstLineStart: Int
    // Where the line holding the end of the removed text ends, in the text before the edit.
    private let endLineEnd: Int
    // Where the line holding the end of the inserted text ends, before its break, once the edit is in.
    private let lastLineContentEnd: Int

    init(range: NSRange, replacement: String, in buffer: VimTextBuffer) {
        location = range.location
        end = NSMaxRange(range)
        removed = Array(buffer.string(in: range).utf16)
        inserted = Array(replacement.utf16)
        delta = inserted.count - removed.count
        let removedBreaks = removed.filter { $0 == 0x0A }.count
        insertedBreaks = inserted.filter { $0 == 0x0A }.count
        removesLineBreak = removedBreaks > 0
        keepsLines = removedBreaks == insertedBreaks
        let firstLine = buffer.lineRange(forOffset: range.location)
        firstLineStart = firstLine.location
        let removedEndsWithBreak = removed.last.map { $0 == 0x0A } ?? true
        let insertedEndsWithBreak = inserted.last.map { $0 == 0x0A } ?? true
        isLinewise = range.location == firstLine.location && removedEndsWithBreak && insertedEndsWithBreak
        let endLine = buffer.lineRange(forOffset: end)
        endLineEnd = NSMaxRange(endLine)
        let endLineHasBreak = endLineEnd > endLine.location && buffer.character(at: endLineEnd - 1) == 0x0A
        lastLineContentEnd = (endLineHasBreak ? endLineEnd - 1 : endLineEnd) + delta
    }

    // Nil when the edit removes the line of a removable mark. `keepsColumn` is false where the mark moved onto
    // another line's text, as a join moves it.
    // An insertion point may sit after a line's last character; a mark sits on a character.
    func map(
        _ offset: Int,
        removable: Bool,
        isInsertionPoint: Bool = false,
        in buffer: VimTextBuffer
    ) -> (offset: Int, keepsColumn: Bool)? {
        let lineEndSlack = isInsertionPoint ? 1 : 0
        let onFirstLine = { self.keepingColumnOnFirstLine($0, lineEndSlack: lineEndSlack) }
        if offset < location { return (offset, true) }
        if offset >= endLineEnd { return (offset + delta, true) }
        if keepsLines { return (keepingLineAndColumn(offset, lineEndSlack: lineEndSlack), true) }
        if isLinewise {
            if offset >= end { return (offset + delta, true) }
            return removable ? nil : (location, false)
        }
        if offset >= end {
            return removesLineBreak ? (offset + delta, false) : (onFirstLine(offset), true)
        }
        if removesLineBreak {
            let line = buffer.lineRange(forOffset: offset)
            if line.location > firstLineStart {
                if NSMaxRange(line) <= end { return removable ? nil : (location, false) }
                return (end + delta, false)
            }
        }
        return (onFirstLine(offset), true)
    }

    // The first line keeps its start, so the offset keeps its column, up to the line's new last character.
    private func keepingColumnOnFirstLine(_ offset: Int, lineEndSlack: Int) -> Int {
        let firstBreak = inserted.firstIndex(of: 0x0A)
        let contentEnd = firstBreak.map { location + $0 } ?? lastLineContentEnd
        return min(offset, max(firstLineStart, contentEnd - 1 + lineEndSlack))
    }

    // The mark's line is the same line of the new text, at the same column up to that line's last character.
    private func keepingLineAndColumn(_ offset: Int, lineEndSlack: Int) -> Int {
        var line = 0
        var lineStart = firstLineStart
        for index in 0..<min(offset - location, removed.count) where removed[index] == 0x0A {
            line += 1
            lineStart = location + index + 1
        }
        let column = offset - lineStart
        let newStart = line == 0 ? firstLineStart : location + nthBreak(line) + 1
        let newContentEnd = line < insertedBreaks ? location + nthBreak(line + 1) : lastLineContentEnd
        return newStart + min(column, max(0, newContentEnd - newStart - 1 + lineEndSlack))
    }

    private func nthBreak(_ count: Int) -> Int {
        var seen = 0
        for (index, unit) in inserted.enumerated() where unit == 0x0A {
            seen += 1
            if seen == count { return index }
        }
        return inserted.count
    }
}
