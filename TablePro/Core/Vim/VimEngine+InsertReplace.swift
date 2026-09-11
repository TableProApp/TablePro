//
//  VimEngine+InsertReplace.swift
//  TablePro
//

import CodeEditTextView
import Foundation

enum VimInsertControl: Character {
    case outdentLine = "\u{04}"
    case indentLine = "\u{14}"
    case deleteToLineStart = "\u{15}"
    case deleteWordBackward = "\u{17}"
}

extension VimEngine {
    nonisolated static let backspaceCharacters: Set<Character> = ["\u{08}", "\u{7F}"]

    func processInsert(_ char: Character) -> Bool {
        if char == "\u{1B}" {
            lastInsertOffset = buffer?.selectedRange().location
            setMode(.normal)
            if let buffer, buffer.selectedRange().location > 0 {
                let pos = buffer.selectedRange().location
                let lineRange = buffer.lineRange(forOffset: pos)
                if pos > lineRange.location {
                    buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
                }
            }
            return true
        }
        guard let buffer, let control = VimInsertControl(rawValue: char) else { return false }
        performInsertControl(control, in: buffer)
        return true
    }

    func processReplace(_ char: Character) -> Bool {
        guard let buffer else { return false }
        if char == "\u{1B}" {
            setMode(.normal)
            let pos = buffer.selectedRange().location
            let lineRange = buffer.lineRange(forOffset: pos)
            if pos > lineRange.location {
                buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
            }
            return true
        }
        if let control = VimInsertControl(rawValue: char) {
            replaceModeEdits.removeAll()
            performInsertControl(control, in: buffer)
            return true
        }
        if char == "\r" || char == "\n" {
            return false
        }
        if Self.backspaceCharacters.contains(char) {
            backspaceInReplace(in: buffer)
            return true
        }
        if Self.isUnwritableControl(char) { return true }
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        if pos < contentEnd {
            let overwritten = NSRange(location: pos, length: 1)
            replaceModeEdits.append(VimReplaceModeEdit(offset: pos, original: buffer.string(in: overwritten)))
            buffer.replaceCharacters(in: overwritten, with: String(char))
        } else {
            replaceModeEdits.append(VimReplaceModeEdit(offset: pos, original: nil))
            buffer.replaceCharacters(in: NSRange(location: pos, length: 0), with: String(char))
        }
        return true
    }

    func backspaceInReplace(in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos > 0 else { return }
        if let last = replaceModeEdits.last, last.offset == pos - 1 {
            replaceModeEdits.removeLast()
            buffer.replaceCharacters(in: NSRange(location: pos - 1, length: 1), with: last.original ?? "")
        } else {
            replaceModeEdits.removeAll()
        }
        buffer.setSelectedRange(NSRange(location: pos - 1, length: 0))
    }

    nonisolated static func isUnwritableControl(_ char: Character) -> Bool {
        guard char.unicodeScalars.count == 1, let scalar = char.unicodeScalars.first else { return false }
        return SpecialCharacter.isTextInputControl(scalar)
    }

    func processCommandLine(_ char: Character, buffer commandBuffer: String) -> Bool {
        switch char {
        case "\u{1B}":
            setMode(.normal)
            return true
        case "\r", "\n":
            let prefix = commandBuffer.first
            let body = String(commandBuffer.dropFirst())
            setMode(.normal)
            if prefix == "/" {
                runSearch(pattern: body, forward: true)
            } else if prefix == "?" {
                runSearch(pattern: body, forward: false)
            } else {
                onCommand?(body)
            }
            return true
        case "\u{7F}", "\u{08}":
            if (commandBuffer as NSString).length > 1 {
                setMode(.commandLine(buffer: String(commandBuffer.dropLast())))
            } else {
                setMode(.normal)
            }
            return true
        default:
            guard !Self.isUnwritableControl(char) else { return true }
            setMode(.commandLine(buffer: commandBuffer + String(char)))
            return true
        }
    }

    func performInsertControl(_ control: VimInsertControl, in buffer: VimTextBuffer) {
        switch control {
        case .deleteWordBackward:
            deleteBackwardInInsert(to: wordStartBeforeCaret(in: buffer), in: buffer)
        case .deleteToLineStart:
            deleteBackwardInInsert(to: lineStartBeforeCaret(in: buffer), in: buffer)
        case .indentLine:
            indentLineInInsert(outdent: false, in: buffer)
        case .outdentLine:
            indentLineInInsert(outdent: true, in: buffer)
        }
    }

    func wordStartBeforeCaret(in buffer: VimTextBuffer) -> Int {
        let pos = buffer.selectedRange().location
        let lineStart = lineStartBeforeCaret(in: buffer)
        guard pos > lineStart else { return pos }
        return max(lineStart, buffer.wordBoundary(forward: false, from: pos))
    }

    func lineStartBeforeCaret(in buffer: VimTextBuffer) -> Int {
        buffer.lineRange(forOffset: buffer.selectedRange().location).location
    }

    func deleteBackwardInInsert(to target: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        guard pos > target else { return }
        buffer.replaceCharacters(in: NSRange(location: target, length: pos - target), with: "")
        buffer.setSelectedRange(NSRange(location: target, length: 0))
    }

    func indentLineInInsert(outdent: Bool, in buffer: VimTextBuffer) {
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
}
