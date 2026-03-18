//
//  SuggestionTriggerCharacterModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 8/25/25.
//

import AppKit
import CodeEditTextView
import TextStory

/// Triggers the suggestion window when trigger characters are typed.
/// Designed to be called in the ``TextViewDelegate``'s didReplaceCharacters method.
///
/// Was originally a `TextFilter` model, however those are called before text is changed and cursors are updated.
/// The suggestion model expects up-to-date cursor positions as well as complete text contents. This being
/// essentially a textview delegate ensures both of those promises are upheld.
@MainActor
final class SuggestionTriggerCharacterModel {
    weak var controller: TextViewController?
    private var lastPosition: NSRange?

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        guard let controller, let completionDelegate = controller.completionDelegate else {
            return
        }

        let triggerCharacters = completionDelegate.completionTriggerCharacters()

        let mutation = TextMutation(
            string: string,
            range: range,
            limit: textView.textStorage.length
        )
        guard mutation.delta >= 0,
              let lastChar = mutation.string.last else {
            lastPosition = nil
            return
        }

        guard triggerCharacters.contains(String(lastChar)) || lastChar.isNumber || lastChar.isLetter else {
            lastPosition = nil
            return
        }

        let range = NSRange(location: mutation.postApplyRange.max, length: 0)
        lastPosition = range
        SuggestionController.shared.cursorsUpdated(
            textView: controller,
            delegate: completionDelegate,
            position: CursorPosition(range: range),
            presentIfNot: true
        )
    }

    func selectionUpdated(_ position: CursorPosition) {
        guard let controller, let completionDelegate = controller.completionDelegate else {
            return
        }

        if lastPosition != position.range {
            SuggestionController.shared.cursorsUpdated(
                textView: controller,
                delegate: completionDelegate,
                position: position
            )
        }
    }
}
