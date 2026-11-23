//
//  VimEngine+Repeat.swift
//  TablePro
//

import Foundation

extension VimEngine {
    func noteEdit(at offset: Int, in buffer: VimTextBuffer) {
        let line = buffer.lineAndColumn(forOffset: offset).line
        if let last = lastEditedLine, last == line {
            editsOnCurrentLine += 1
        } else {
            editsOnCurrentLine = 1
            lastEditedLine = line
        }
    }

    // Every edit the engine makes goes through here, so a command that changed the text is the one `.` repeats.
    func replace(_ range: NSRange, with string: String, in buffer: VimTextBuffer) {
        changeDraft?.changesText = true
        buffer.replaceCharacters(in: range, with: string)
    }

    // A change starts at the first key of a Normal mode command, count and register included. Typed keys are not kept:
    // the text view applies them, so what they did is read from the text.
    func changeKeyWillProcess(_ char: Character, shift: Bool) {
        guard !isRepeatingChange else { return }
        if changeDraft == nil {
            guard mode == .normal else { return }
            changeDraft = VimChangeDraft()
        }
        guard mode != .insert else {
            if changeDraft?.insertedRange != nil, VimInsertControl(rawValue: char) != nil {
                let typed = takeTypedStep()
                changeDraft?.insertSteps += [typed, .key(char)].compactMap { $0 }
            }
            return
        }
        let isCount = mode == .normal && isCountKey(char)
        changeDraft?.keys.append(VimChangeKey(character: char, shift: shift, isCount: isCount))
    }

    // Ends the typed run, which the next edit starts again at the caret.
    private func takeTypedStep() -> VimInsertStep? {
        guard let draft = changeDraft, let range = draft.insertedRange else { return nil }
        changeDraft?.insertedRange = nil
        changeDraft?.deletedBeforeInsert = 0
        let text = buffer?.string(in: range) ?? ""
        guard draft.deletedBeforeInsert > 0 || !text.isEmpty else { return nil }
        return .typed(deleting: draft.deletedBeforeInsert, text: text)
    }

    func changeKeyDidProcess() {
        guard !isRepeatingChange, let draft = changeDraft else { return }
        switch mode {
        case .insert:
            guard draft.insertedRange == nil else { return }
            changeDraft?.changesText = true
            changeDraft?.insertedRange = NSRange(location: buffer?.selectedRange().location ?? 0, length: 0)
        case .replace:
            changeDraft?.changesText = true
        case .normal:
            guard !hasPendingCommand, countPrefix == 0, operatorCount == 0, selectedRegister == nil else { return }
            let typed = takeTypedStep()
            changeDraft = nil
            guard draft.changesText else { return }
            let enteredInsert = draft.insertedRange != nil || !draft.insertSteps.isEmpty
            let steps = draft.insertSteps + [typed].compactMap { $0 }
            lastChange = VimChange(keys: draft.keys, insertSteps: enteredInsert ? steps : nil)
        case .visual, .commandLine:
            return
        }
    }

    // Keeps the range of the text typed since Insert mode began in step with every edit, typed or not.
    func noteInsertedText(in range: NSRange, with replacement: String) {
        guard mode == .insert, let inserted = changeDraft?.insertedRange else { return }
        let replacementLength = (replacement as NSString).length
        let delta = replacementLength - range.length
        if NSMaxRange(range) < inserted.location {
            changeDraft?.insertedRange = NSRange(location: inserted.location + delta, length: inserted.length)
        } else if range.location > NSMaxRange(inserted) {
            // Typing somewhere else starts the insert over there, as moving the cursor in Insert mode does in Vim.
            changeDraft?.insertSteps = []
            changeDraft?.deletedBeforeInsert = 0
            changeDraft?.insertedRange = NSRange(location: range.location, length: replacementLength)
        } else {
            // Backspace past where the typing began deletes text the repeat has to delete too.
            let deletedBefore = inserted.location - range.location - replacementLength
            if deletedBefore > 0, let buffer {
                let deleted = buffer.string(in: NSRange(location: range.location + replacementLength, length: deletedBefore))
                changeDraft?.deletedBeforeInsert += deleted.count
            }
            let start = range.location < inserted.location
                ? min(inserted.location, range.location + replacementLength)
                : inserted.location
            let end = NSMaxRange(range) >= NSMaxRange(inserted)
                ? range.location + replacementLength
                : NSMaxRange(inserted) + delta
            changeDraft?.insertedRange = NSRange(location: start, length: max(0, end - start))
        }
    }

    // A count given to `.` replaces the change's own, and the change keeps it, as in Vim.
    func repeatLastChange(count: Int?) {
        changeDraft = nil
        guard !isRepeatingChange, var change = lastChange else { return }
        if let count {
            change.keys = String(count).map { VimChangeKey(character: $0, shift: false, isCount: true) }
                + change.keys.filter { !$0.isCount }
            lastChange = change
        }
        let recording = macroRecording
        macroRecording = nil
        isRepeatingChange = true
        defer {
            isRepeatingChange = false
            macroRecording = recording
        }
        for key in change.keys {
            _ = process(key.character, shift: key.shift)
        }
        if let buffer {
            for step in change.insertSteps ?? [] where mode == .insert {
                switch step {
                case .typed(let deleting, let text):
                    deleteBeforeCaret(deleting, in: buffer)
                    if !text.isEmpty {
                        replace(NSRange(location: buffer.selectedRange().location, length: 0), with: text, in: buffer)
                    }
                case .key(let key):
                    _ = process(key, shift: false)
                }
            }
        }
        if mode != .normal {
            _ = process("\u{1B}", shift: false)
        }
    }

    private func deleteBeforeCaret(_ count: Int, in buffer: VimTextBuffer) {
        let caret = buffer.selectedRange().location
        let start = characterOffset(before: caret, count: count, limit: 0, in: buffer)
        guard start < caret else { return }
        replace(NSRange(location: start, length: caret - start), with: "", in: buffer)
    }
}
