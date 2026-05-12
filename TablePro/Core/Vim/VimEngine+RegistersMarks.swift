//
//  VimEngine+RegistersMarks.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func writeToActiveRegister(text: String, linewise: Bool, asDelete: Bool) {
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

    func jumpToMark(_ name: Character, exact: Bool, in buffer: VimTextBuffer) {
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

    func recordVisualSelection(linewise: Bool, in buffer: VimTextBuffer) {
        let sel = buffer.selectedRange()
        guard sel.length > 0 else { return }
        lastVisualStart = sel.location
        lastVisualEnd = sel.location + sel.length - 1
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
            let length = clampedEnd - clampedStart + (clampedEnd < buffer.length ? 1 : 0)
            buffer.setSelectedRange(NSRange(location: clampedStart, length: length))
            setMode(.visual(linewise: false))
        }
    }

    func adjustMarksForEdit(in editRange: NSRange, replacementLength: Int) {
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
}
