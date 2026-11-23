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

    // A change starts at the first key of a Normal mode command, count and register included. In Insert and Replace
    // mode a key the text view applies is not kept: what it did is read from the text.
    func changeKeyWillProcess(_ char: Character, shift: Bool) {
        guard !isRepeatingChange else { return }
        if changeDraft == nil {
            guard mode == .normal else { return }
            changeDraft = VimChangeDraft()
        }
        guard !mode.isInsert else {
            if changeDraft?.insertedRange != nil, engineApplies(char) {
                let typed = takeTypedStep()
                changeDraft?.insertSteps += [typed, .key(char)].compactMap { $0 }
            }
            return
        }
        if mode.isVisual, !hasPendingVisualKey, let buffer {
            let commandStart = changeDraft?.keys.count ?? 0
            changeDraft?.visualExtent = visualExtent(of: buffer.selectedRange(), in: buffer)
            changeDraft?.visualCommandStart = commandStart
            changeDraft?.visualRegister = selectedRegister
        }
        let isCount = mode == .normal && isCountKey(char)
        changeDraft?.keys.append(VimChangeKey(character: char, shift: shift, isCount: isCount))
    }

    // Replace mode overwrites with every key but Return, which the text view inserts. Escape ends the change.
    private func engineApplies(_ char: Character) -> Bool {
        guard char != "\u{1B}" else { return false }
        if mode == .replace { return char != "\r" && char != "\n" }
        return VimInsertControl(rawValue: char) != nil
    }

    private var hasPendingVisualKey: Bool {
        pendingG || pendingReplaceCharForVisual || pendingTextObject || pendingRegisterSelect
    }

    private func visualExtent(of selection: NSRange, in buffer: VimTextBuffer) -> VimVisualExtent {
        let last = selection.length > 0 ? characterStart(at: NSMaxRange(selection) - 1, in: buffer) : selection.location
        let first = buffer.lineAndColumn(forOffset: selection.location)
        let end = buffer.lineAndColumn(forOffset: last)
        let lines = end.line - first.line + 1
        return VimVisualExtent(
            linewise: mode.isVisualLinewise,
            lines: lines,
            characters: lines == 1 ? buffer.string(in: selection).count : 0,
            lastColumn: end.column
        )
    }

    // The keys of the command that ended Visual mode, behind the register it was given.
    private func visualOperatorKeys(of draft: VimChangeDraft) -> [VimChangeKey] {
        let keys = Array(draft.keys[draft.visualCommandStart...])
        guard let register = draft.visualRegister else { return keys }
        let named = [Character("\""), register].map { VimChangeKey(character: $0, shift: false, isCount: false) }
        return named + keys
    }

    // Selects as much from the caret as the change's selection held, in the same Visual mode.
    private func selectVisualExtent(_ extent: VimVisualExtent, in buffer: VimTextBuffer) {
        let caret = buffer.selectedRange().location
        let lastLine = min(buffer.lineCount - 1, buffer.lineAndColumn(forOffset: caret).line + extent.lines - 1)
        let end: Int
        if extent.linewise {
            end = buffer.offset(forLine: lastLine, column: 0)
        } else if extent.lines > 1 {
            end = buffer.offset(forLine: lastLine, column: extent.lastColumn)
        } else {
            let lastOnLine = max(caret, contentEnd(ofLineAt: caret, in: buffer) - 1)
            end = characterOffset(after: caret, count: extent.characters - 1, limit: lastOnLine, in: buffer)
        }
        visualAnchor = caret
        cursorOffset = caret
        setMode(.visual(linewise: extent.linewise))
        updateVisualSelection(cursorPos: end, linewise: extent.linewise, in: buffer)
    }

    func beginInsert(count: Int, opensLine: Bool = false) {
        insertRepeat = count > 1 ? VimInsertRepeat(count: count, opensLine: opensLine) : nil
        if count > 1 { openInsertUndoStep() }
        setMode(.insert)
    }

    // A counted insert is one undo step, as in Vim, from the line `o` opens through the copies typed at Escape.
    func openInsertUndoStep() {
        guard !insertUndoStepOpen, let buffer else { return }
        insertUndoStepOpen = buffer.beginUndoStep()
    }

    // Insert mode can also end by a reset, another document, an undo, focus leaving the editor or Vim turned off.
    func closeInsertUndoStep() {
        guard insertUndoStepOpen else { return }
        insertUndoStepOpen = false
        buffer?.endUndoStep()
    }

    // At Escape a counted insert types what this one did again, count - 1 more times.
    func repeatCountedInsert() {
        guard let pending = insertRepeat else { return }
        insertRepeat = nil
        guard !isRepeatingChange, changeDraft != nil, let buffer else { return }
        if let typed = takeTypedStep() {
            changeDraft?.insertSteps.append(typed)
        }
        let steps = changeDraft?.insertSteps ?? []
        let recording = macroRecording
        macroRecording = nil
        isRepeatingChange = true
        defer {
            isRepeatingChange = false
            macroRecording = recording
        }
        applyInsertSteps(steps, times: pending.count - 1, opensLine: pending.opensLine, in: buffer)
    }

    private func applyInsertSteps(_ steps: [VimInsertStep], times: Int, opensLine: Bool, in buffer: VimTextBuffer) {
        for _ in 0..<max(0, times) {
            if opensLine {
                replace(NSRange(location: buffer.selectedRange().location, length: 0), with: "\n", in: buffer)
            }
            for step in steps where mode.isInsert {
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
        case .insert, .replace:
            guard draft.insertedRange == nil else { return }
            let caret = buffer?.selectedRange().location ?? 0
            changeDraft?.changesText = true
            changeDraft?.insertedRange = NSRange(location: caret, length: 0)
            changeDraft?.insertCaret = caret
            changeDraft?.editedSinceCaret = false
        case .normal:
            guard !hasPendingCommand, countPrefix == 0, operatorCount == 0, selectedRegister == nil else { return }
            let typed = takeTypedStep()
            changeDraft = nil
            guard draft.changesText else { return }
            let enteredInsert = draft.insertedRange != nil || !draft.insertSteps.isEmpty
            let steps = draft.insertSteps + [typed].compactMap { $0 }
            let visual = draft.visualExtent.map { VimVisualChange(extent: $0, operatorKeys: visualOperatorKeys(of: draft)) }
            lastChange = VimChange(keys: draft.keys, insertSteps: enteredInsert ? steps : nil, visual: visual)
        case .visual, .commandLine:
            return
        }
    }

    // Keeps the range of the text typed since Insert or Replace mode began in step with every edit, typed or not.
    func noteInsertedText(in range: NSRange, with replacement: String) {
        guard mode.isInsert, let inserted = changeDraft?.insertedRange else { return }
        changeDraft?.editedSinceCaret = true
        let replacementLength = (replacement as NSString).length
        let delta = replacementLength - range.length
        if NSMaxRange(range) < inserted.location {
            changeDraft?.insertedRange = NSRange(location: inserted.location + delta, length: inserted.length)
        } else if range.location > NSMaxRange(inserted) {
            // Typing somewhere else means the caret moved there first.
            restartInsert(at: range.location)
            changeDraft?.insertedRange = NSRange(location: range.location, length: replacementLength)
            changeDraft?.editedSinceCaret = true
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

    // A selection change right after an edit is where that edit left the caret, and one to the same place repeats it.
    // Any other is a move: arrows, Home and End, a click. In Vim a move in Insert or Replace mode starts a new insert
    // where it lands, and `.` repeats only what is typed after it.
    func selectionDidChange() {
        guard mode.isInsert, !isRepeatingChange, let draft = changeDraft, draft.insertedRange != nil,
              let caret = buffer?.selectedRange().location else { return }
        if draft.editedSinceCaret {
            changeDraft?.insertCaret = caret
            changeDraft?.editedSinceCaret = false
        } else if caret != draft.insertCaret {
            restartInsert(at: caret)
        }
    }

    private func restartInsert(at caret: Int) {
        let command: Character = mode == .replace ? "R" : "i"
        changeDraft?.keys = [VimChangeKey(character: command, shift: command == "R", isCount: false)]
        changeDraft?.insertSteps = []
        changeDraft?.deletedBeforeInsert = 0
        changeDraft?.visualExtent = nil
        changeDraft?.insertedRange = NSRange(location: caret, length: 0)
        changeDraft?.insertCaret = caret
        changeDraft?.editedSinceCaret = false
        insertRepeat = nil
        closeInsertUndoStep()
    }

    // A count given to `.` replaces the change's own, and the change keeps it, as in Vim.
    func repeatLastChange(count: Int?) {
        changeDraft = nil
        guard !isRepeatingChange, var change = lastChange, let buffer else { return }
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
        // One `.` is one undo step, as in Vim, though the operator's delete and the typed text are separate edits.
        buffer.performAsOneUndoStep { replay(change, in: buffer) }
    }

    private func replay(_ change: VimChange, in buffer: VimTextBuffer) {
        if let visual = change.visual {
            selectVisualExtent(visual.extent, in: buffer)
            for key in visual.operatorKeys {
                _ = process(key.character, shift: key.shift)
            }
        } else {
            for key in change.keys {
                _ = process(key.character, shift: key.shift)
            }
        }
        if mode.isInsert {
            let pending = insertRepeat
            insertRepeat = nil
            let steps = change.insertSteps ?? []
            applyInsertSteps(steps, times: 1, opensLine: false, in: buffer)
            if let pending {
                applyInsertSteps(steps, times: pending.count - 1, opensLine: pending.opensLine, in: buffer)
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
