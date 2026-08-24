//
//  TextViewerWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class TextViewerWindowController: ValueViewerWindowController {
    static func open(
        text: String?,
        columnName: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?
    ) {
        let title: String
        if let columnName {
            title = String(format: String(localized: "Text: %@"), columnName)
        } else {
            title = String(localized: "Text Viewer")
        }

        let controller = TextViewerWindowController()
        controller.present(
            identifier: "text-viewer",
            title: title,
            autosaveName: "TextViewerWindow"
        ) { dismiss in
            TextViewerWindowContent(
                initialValue: text,
                isEditable: isEditable,
                onCommit: onCommit,
                onDismiss: dismiss
            )
        }
    }
}

// MARK: - Window Content

private struct TextViewerWindowContent: View {
    let isEditable: Bool
    let onCommit: ((String) -> Void)?
    let onDismiss: (() -> Void)?

    @State private var text: String

    init(
        initialValue: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?,
        onDismiss: (() -> Void)?
    ) {
        self.isEditable = isEditable
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._text = State(initialValue: initialValue ?? "")
    }

    var body: some View {
        TextValueEditor(
            text: $text,
            isEditable: isEditable,
            font: ThemeEngine.shared.valueFont,
            textContainerInset: NSSize(width: 8, height: 10)
        )
        .onChange(of: text) {
            guard isEditable else { return }
            onCommit?(text)
        }
        .onExitCommand { onDismiss?() }
    }
}
