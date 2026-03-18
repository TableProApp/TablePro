//
//  TextViewController+TextViewDelegate.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/14/23.
//

import Foundation
import CodeEditTextView
import TextStory

extension TextViewController: TextViewDelegate {
    public func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
        for coordinator in self.textCoordinators.values() {
            if let coordinator = coordinator as? TextViewDelegate {
                coordinator.textView(textView, willReplaceContentsIn: range, with: string)
            }
        }
    }

    public func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        gutterView.needsDisplay = true
        for coordinator in self.textCoordinators.values() {
            if let coordinator = coordinator as? TextViewDelegate {
                coordinator.textView(textView, didReplaceContentsIn: range, with: string)
            } else {
                coordinator.textViewDidChangeText(controller: self)
            }
        }

        suggestionTriggerModel.textView(textView, didReplaceContentsIn: range, with: string)
    }

    public func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool {
        let mutation = TextMutation(
            string: string,
            range: range,
            limit: textView.textStorage.length
        )

        return shouldApplyMutation(mutation, to: textView)
    }
}
