//
//  TextBindingSync.swift
//  TableProEditorKit
//
//  Owns the two-way synchronization between a SwiftUI text binding and the
//  text view: editor edits are written back to the binding (debounced for
//  large documents), and external binding changes are pushed down into the
//  editor. The shared ``RepresentableSyncPhase`` decides which side wins
//  when both have changes in flight.
//

import AppKit
import SwiftUI
import TableProTextEngine

@MainActor
final class TextBindingSync {
    private static let writebackDebounceThreshold = 500_000
    private static let writebackDebounce: Duration = .milliseconds(150)

    var text: SourceEditor.TextAPI
    private(set) var lastSyncedText: String?
    private(set) var documentID: AnyHashable?

    private let phase: RepresentableSyncPhase
    private(set) var writebackTask: Task<Void, Never>?

    init(text: SourceEditor.TextAPI, documentID: AnyHashable? = nil, phase: RepresentableSyncPhase) {
        self.text = text
        self.documentID = documentID
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
            self.writebackTask = nil
            currentBinding.wrappedValue = newText
        }
    }

    // A run or save reads the binding, which trails the editor by the debounce on a large document.
    func flushPendingWriteback(from textView: TextView) {
        guard writebackTask != nil else { return }
        let newText = endPendingWriteback(from: textView)
        guard case .binding(let binding) = text else { return }
        binding.wrappedValue = newText
    }

    // For an owner about to point the binding at another document, or to drop the editor: the debounced edit goes
    // to the caller, and the edit latch is released so the next document's text is applied.
    func takePendingWriteback(from textView: TextView) -> String? {
        guard writebackTask != nil else { return nil }
        let newText = endPendingWriteback(from: textView)
        phase.consumePendingEditorChange()
        return newText
    }

    private func endPendingWriteback(from textView: TextView) -> String {
        writebackTask?.cancel()
        writebackTask = nil
        let newText = textView.string
        lastSyncedText = newText
        return newText
    }

    // The editor's content wins while one of its own edits is in flight. In the same named document a new value is one
    // undoable edit; another document, or an owner that names none, gets `setText`: a new history and a highlighter
    // rebuilt for the new storage, even when the text is the same.
    func applyRepresentableText(
        _ newValue: String,
        documentID: AnyHashable? = nil,
        controller: TextViewController
    ) {
        guard !phase.isEditorChangePending else { return }
        let isSameDocument = documentID == self.documentID
        self.documentID = documentID
        // Compare with NSString literal equality. The text can be multiple megabytes and bridged from NSTextStorage,
        // so Swift's canonical `!=` walks the whole string through Unicode normalization on every representable update.
        if isSameDocument, let lastSyncedText, (newValue as NSString).isEqual(to: lastSyncedText) { return }

        writebackTask?.cancel()
        writebackTask = nil
        phase.applyRepresentableValue {
            if isSameDocument, documentID != nil {
                controller.replaceDocumentText(newValue)
            } else {
                controller.setText(newValue)
            }
        }
        lastSyncedText = newValue
    }
}

public extension TextViewController {
    static let flushTextWritebackNotification = Notification.Name(
        "TableProEditorKit.flushTextWritebackNotification"
    )

    func flushPendingTextWriteback() {
        guard let textView else { return }
        NotificationCenter.default.post(name: Self.flushTextWritebackNotification, object: textView)
    }
}
