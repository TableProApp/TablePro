import AppKit
import Carbon.HIToolbox
import TableProTextEngine

extension TextViewController {
    public var isSnippetSessionActive: Bool {
        snippetSession != nil
    }

    // One undo group, without the typing filters, so the field offsets match the inserted text.
    public func insertSnippet(_ snippet: EditorSnippet, replacing range: NSRange) {
        endSnippetSession()
        guard textView.isEditable, NSMaxRange(range) <= textView.textStorage.length else { return }

        textView.undoManager?.beginUndoGrouping()
        isApplyingUnfilteredEdits = true
        textView.replaceCharacters(in: range, with: snippet.text)
        isApplyingUnfilteredEdits = false
        textView.undoManager?.endUndoGrouping()

        guard let session = SnippetSession(snippet: snippet, at: range.location) else {
            let length = (snippet.text as NSString).length
            let final = snippet.finalRange ?? NSRange(location: length, length: 0)
            selectSnippetRanges([NSRange(location: range.location + final.location, length: final.length)])
            return
        }
        snippetSession = session
        selectCurrentSnippetField()
    }

    public func endSnippetSession() {
        guard snippetSession != nil else { return }
        snippetSession = nil
        snippetChoiceGeneration += 1
        emphasisManager?.removeEmphases(for: EmphasisGroup.snippetFields)
    }

    // A completion accepted in one copy of a mirrored field goes into every copy, as typing does. False when the edit
    // is not inside a copy of the active field or the copies no longer match, and the caller applies it alone.
    public func replaceInSnippetMirrors(_ range: NSRange, with text: String, caretOffset: Int) -> Bool {
        guard let field = snippetSession?.currentField, field.ranges.count > 1,
              let source = field.ranges.first(where: {
                  $0.location <= range.location && NSMaxRange(range) <= NSMaxRange($0)
              }) else { return false }

        let document = textView.string as NSString
        let sourceText = document.substring(with: source)
        guard field.ranges.allSatisfy({ document.substring(with: $0) == sourceText }) else { return false }

        let offset = range.location - source.location
        let copies = field.ranges.sorted { $0.location < $1.location }
        textView.undoManager?.beginUndoGrouping()
        textView.replaceCharacters(copies.map {
            TextReplacement(range: NSRange(location: $0.location + offset, length: range.length), string: text)
        })
        textView.undoManager?.endUndoGrouping()

        let delta = (text as NSString).length - range.length
        let carets = copies.enumerated().map { index, copy in
            NSRange(location: copy.location + index * delta + offset + caretOffset, length: 0)
        }
        textView.selectionManager.setSelectedRanges(carets)
        return true
    }

    // Consulted after the coordinators and the completion list, so Tab still accepts a completion or a suggestion.
    func claimSnippetKey(_ event: NSEvent, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard snippetSession != nil else { return false }
        switch (Int(event.keyCode), modifierFlags) {
        case (kVK_Tab, []):
            advanceSnippetField()
        case (kVK_Tab, .shift):
            retreatSnippetField()
        case (kVK_Escape, []):
            endSnippetSession()
        default:
            return false
        }
        return true
    }

    func snippetTextDidReplace(in range: NSRange, with string: String) {
        guard var session = snippetSession else { return }
        let isUndo = textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true
        if session.apply(edit: range, replacementLength: (string as NSString).length, isUndo: isUndo) {
            snippetSession = session
        } else {
            endSnippetSession()
        }
    }

    func snippetSelectionDidChange() {
        guard let session = snippetSession else { return }
        let selections = textView.selectionManager.textSelections.map(\.range)
        guard !selections.isEmpty, selections.allSatisfy(session.contains) else {
            endSnippetSession()
            return
        }
        updateSnippetEmphasis()
    }

    private func advanceSnippetField() {
        guard var session = snippetSession else { return }
        guard session.advance() else {
            let final = session.finalRange
            endSnippetSession()
            selectSnippetRanges([final])
            return
        }
        snippetSession = session
        selectCurrentSnippetField()
    }

    private func retreatSnippetField() {
        guard var session = snippetSession else { return }
        session.retreat()
        snippetSession = session
        selectCurrentSnippetField()
    }

    // Every move bumps the generation, so a menu still pending for the field just left cannot fill this one.
    private func selectCurrentSnippetField() {
        snippetChoiceGeneration += 1
        guard let field = snippetSession?.currentField else { return }
        selectSnippetRanges(field.ranges)
        updateSnippetEmphasis()
        guard !field.choices.isEmpty, let anchor = field.ranges.first else { return }

        let generation = snippetChoiceGeneration
        snippetChoicePresenter(field.choices, anchor, textView) { [weak self] choice in
            self?.applySnippetChoice(choice, generation: generation)
        }
    }

    // A pick arriving after the session moved on, or ended, is dropped.
    private func applySnippetChoice(_ choice: String, generation: Int) {
        guard generation == snippetChoiceGeneration, let field = snippetSession?.currentField else { return }

        textView.undoManager?.beginUndoGrouping()
        isApplyingUnfilteredEdits = true
        textView.replaceCharacters(in: field.ranges, with: choice)
        isApplyingUnfilteredEdits = false
        textView.undoManager?.endUndoGrouping()

        guard let updated = snippetSession?.currentField else { return }
        selectSnippetRanges(updated.ranges)
    }

    private func selectSnippetRanges(_ ranges: [NSRange]) {
        textView.selectionManager.setSelectedRanges(ranges)
        textView.scrollSelectionToVisible()
    }

    private func updateSnippetEmphasis() {
        guard let session = snippetSession else { return }
        let emphases = session.fields.flatMap(\.ranges).map {
            Emphasis(range: $0, style: .outline(color: .secondaryLabelColor))
        }
        emphasisManager?.replaceEmphases(emphases, for: EmphasisGroup.snippetFields)
    }
}

typealias SnippetChoicePresenter = @MainActor (
    _ choices: [String],
    _ range: NSRange,
    _ textView: TextView,
    _ onPick: @escaping @MainActor (String) -> Void
) -> Void

enum SnippetChoiceMenu {
    @MainActor
    static func present(
        _ choices: [String],
        at range: NSRange,
        in textView: TextView,
        onPick: @escaping @MainActor (String) -> Void
    ) {
        // After the key event that selected the field returns: the menu runs its own tracking loop.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, textView.window != nil,
                  let caret = textView.layoutManager.rectForOffset(range.location) else { return }

            let target = ChoiceTarget(onPick: onPick)
            let menu = NSMenu()
            menu.autoenablesItems = false
            for choice in choices {
                let item = NSMenuItem(title: choice, action: #selector(ChoiceTarget.pick(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = choice
                menu.addItem(item)
            }
            let point = NSPoint(x: caret.minX, y: textView.isFlipped ? caret.maxY : caret.minY)
            withExtendedLifetime(target) {
                _ = menu.popUp(positioning: nil, at: point, in: textView)
            }
        }
    }

    private final class ChoiceTarget: NSObject {
        let onPick: @MainActor (String) -> Void

        init(onPick: @escaping @MainActor (String) -> Void) {
            self.onPick = onPick
        }

        @MainActor @objc func pick(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? String else { return }
            onPick(choice)
        }
    }
}
