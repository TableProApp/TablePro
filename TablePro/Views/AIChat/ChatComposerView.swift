//
//  ChatComposerView.swift
//  TablePro
//

import SwiftUI

struct ChatComposerView: View {
    @Binding var text: String
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    @Bindable var mentionState: MentionPopoverState
    let onTextChange: (String, Int) -> Void
    let onSubmit: () -> Void
    let onAttach: (ContextItem) -> Void

    @State private var isFocused: Bool = false
    @State private var isCommittingMention = false

    var body: some View {
        ChatComposerTextView(
            text: $text,
            isFocused: $isFocused,
            placeholder: placeholder,
            minLines: minLines,
            maxLines: maxLines,
            isCommittingMention: isCommittingMention,
            onTextChange: { newText, caret in
                guard !isCommittingMention else { return }
                onTextChange(newText, caret)
            },
            onSubmit: { onSubmit() },
            onCommitMention: { commitMentionIfVisible() },
            onArrow: { delta in moveMention(by: delta) },
            onTab: { commitMentionIfVisible() },
            onEscape: { dismissMention() }
        )
        .fixedSize(horizontal: false, vertical: true)
        .background(composerBackground)
        .popover(
            isPresented: popoverBinding,
            attachmentAnchor: .point(.topLeading),
            arrowEdge: .bottom
        ) {
            MentionSuggestionListView(
                state: mentionState,
                onSelect: { commitMention(at: $0) }
            )
        }
    }

    private var composerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                shape.stroke(
                    isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 1 : 0.5
                )
            }
            .animation(.default, value: isFocused)
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { mentionState.isVisible && !mentionState.candidates.isEmpty },
            set: { newValue in
                if !newValue { mentionState.reset() }
            }
        )
    }

    private func commitMentionIfVisible() -> Bool {
        guard mentionState.isVisible, !mentionState.candidates.isEmpty else { return false }
        commitMention(at: mentionState.selectedIndex)
        return true
    }

    private func moveMention(by delta: Int) -> Bool {
        guard mentionState.isVisible, !mentionState.candidates.isEmpty else { return false }
        mentionState.moveSelection(by: delta)
        return true
    }

    private func dismissMention() -> Bool {
        guard mentionState.isVisible else { return false }
        mentionState.reset()
        return true
    }

    private func commitMention(at index: Int) {
        guard mentionState.candidates.indices.contains(index) else { return }
        let candidate = mentionState.candidates[index]
        let nsText = text as NSString
        let range = mentionState.anchorRange
        guard range.location >= 0, NSMaxRange(range) <= nsText.length else {
            mentionState.reset()
            return
        }
        isCommittingMention = true
        defer { isCommittingMention = false }
        let prefix = nsText.substring(to: range.location)
        let suffix = nsText.substring(from: NSMaxRange(range))
        text = prefix + suffix
        onAttach(candidate.item)
        mentionState.reset()
    }
}
