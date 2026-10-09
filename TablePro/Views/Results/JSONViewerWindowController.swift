//
//  JSONViewerWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class JSONViewerWindowController: ValueViewerWindowController {
    @discardableResult
    static func open(
        text: String?,
        columnName: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?
    ) -> JSONViewerWindowController {
        open(text: text, baseline: text, columnName: columnName, isEditable: isEditable, onCommit: onCommit)
    }

    /// `baseline` is the stored value Save compares against. It differs from `text` when the window
    /// opens on an edit nothing has committed, which Save would otherwise read as no change.
    @discardableResult
    static func open(
        text: String?,
        baseline: String?,
        columnName: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?
    ) -> JSONViewerWindowController {
        let title: String
        if let columnName {
            title = String(format: String(localized: "JSON: %@"), columnName)
        } else {
            title = String(localized: "JSON Viewer")
        }

        let controller = JSONViewerWindowController()
        controller.present(
            identifier: "json-viewer",
            title: title,
            autosaveName: "JSONViewerWindow"
        ) { dismiss in
            JSONViewerWindowContent(
                initialValue: text,
                baseline: baseline,
                isEditable: isEditable,
                onCommit: onCommit,
                onDismiss: dismiss
            )
        }
        return controller
    }

    /// Nil when Save would write back what is stored. A NULL baseline reads as empty text, so an
    /// empty Save leaves the cell NULL rather than writing an empty string over it.
    nonisolated static func valueToCommit(saved: String, baseline: String?) -> String? {
        saved == JsonReindenter.normalize(baseline ?? "") ? nil : saved
    }
}

// MARK: - Window Content

private struct JSONViewerWindowContent: View {
    let baseline: String?
    let isEditable: Bool
    let onCommit: ((String) -> Void)?
    let onDismiss: (() -> Void)?

    @State private var text: String

    init(
        initialValue: String?,
        baseline: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?,
        onDismiss: (() -> Void)?
    ) {
        self.baseline = baseline
        self.isEditable = isEditable
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._text = State(initialValue: initialValue ?? "")
    }

    var body: some View {
        JSONViewerView(
            text: $text,
            isEditable: isEditable,
            onDismiss: onDismiss,
            onCommit: isEditable ? { newValue in
                if let value = JSONViewerWindowController.valueToCommit(saved: newValue, baseline: baseline) {
                    onCommit?(value)
                }
            } : nil
        )
    }
}
