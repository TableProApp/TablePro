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
                isEditable: isEditable,
                onCommit: onCommit,
                onDismiss: dismiss
            )
        }
        return controller
    }
}

// MARK: - Window Content

private struct JSONViewerWindowContent: View {
    let initialValue: String?
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
        self.initialValue = initialValue
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
                if newValue.isEmpty && initialValue == nil { return }
                if newValue != JsonReindenter.normalize(initialValue ?? "") {
                    onCommit?(newValue)
                }
            } : nil
        )
    }
}
