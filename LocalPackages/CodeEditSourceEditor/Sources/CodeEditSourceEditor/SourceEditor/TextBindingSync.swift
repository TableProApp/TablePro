//
//  TextBindingSync.swift
//  CodeEditSourceEditor
//
//  Owns the two-way synchronization between a SwiftUI text binding and the
//  text view: editor edits are written back to the binding (debounced for
//  large documents), and external binding changes are pushed down into the
//  editor. The shared ``RepresentableSyncPhase`` decides which side wins
//  when both have changes in flight.
//

import AppKit
import CodeEditTextView
import SwiftUI

@MainActor
final class TextBindingSync {
    private static let writebackDebounceThreshold = 500_000
    private static let writebackDebounce: Duration = .milliseconds(150)

    var text: SourceEditor.TextAPI
    private(set) var lastSyncedText: String?

    private let phase: RepresentableSyncPhase
    private var writebackTask: Task<Void, Never>?

    init(text: SourceEditor.TextAPI, phase: RepresentableSyncPhase) {
        self.text = text
        self.phase = phase
        if case .binding(let binding) = text {
            lastSyncedText = binding.wrappedValue
        }
    }

    /// Writes an editor-originated text change back to the binding.
    ///
    /// Marks the phase before writing so the representable update pass that
    /// the binding write triggers cannot clobber the editor with a stale
    /// snapshot. For large documents the writeback is debounced to avoid
    /// copying megabytes into SwiftUI on every keystroke; the phase is still
    /// marked immediately so the editor stays the source of truth during the
    /// debounce window.
    func editorTextDidChange(_ textView: TextView) {
        guard !phase.isApplyingRepresentableValue else { return }
        guard case .binding(let binding) = text else { return }

        phase.markEditorChange()

        guard textView.textStorage.length > Self.writebackDebounceThreshold else {
            let newText = textView.string
            lastSyncedText = newText
            binding.wrappedValue = newText
            return
        }

        writebackTask?.cancel()
        writebackTask = Task { @MainActor [weak self, weak textView] in
            try? await Task.sleep(for: Self.writebackDebounce)
            guard !Task.isCancelled, let self, let textView else { return }
            guard case .binding(let currentBinding) = self.text else { return }
            let newText = textView.string
            self.lastSyncedText = newText
            currentBinding.wrappedValue = newText
        }
    }

    /// Pushes an external binding change down into the text view. The editor's
    /// content wins while one of its own edits is still in flight, so user
    /// typing is never clobbered by a stale binding snapshot.
    ///
    /// Routes through `TextViewController.setText` on purpose. The text-view
    /// level `replaceCharacters` is the user-edit path: it is gated on
    /// `isEditable`, runs mutation filters, and fires suggestion triggers,
    /// none of which should happen for a programmatic whole-document
    /// replacement. The controller-level call also rebuilds the highlighter
    /// for the replacement storage; calling the text view directly leaves
    /// tree-sitter state for the old document and highlighting never recovers.
    func applyRepresentableText(_ newValue: String, controller: TextViewController) {
        guard !phase.isEditorChangePending else { return }
        guard newValue != lastSyncedText else { return }

        writebackTask?.cancel()
        phase.applyRepresentableValue {
            controller.setText(newValue)
        }
        lastSyncedText = newValue
    }
}
