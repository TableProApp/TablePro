//
//  CellImageWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The pop-out window for a cell that holds an image. Read-only on purpose: editing a value stays
/// with the popover and the row inspector, which are the two places that can record a change.
@MainActor
internal final class CellImageWindowController: ValueViewerWindowController {
    static func open(
        data: Data,
        format: CellImageFormat,
        sourceKind: CellImageSourceKind,
        columnName: String?
    ) {
        let title: String
        if let columnName {
            title = String(format: String(localized: "Image: %@"), columnName)
        } else {
            title = String(localized: "Image Viewer")
        }

        let controller = CellImageWindowController()
        controller.present(
            identifier: "cell-image-viewer",
            title: title,
            autosaveName: "CellImageViewerWindow"
        ) { dismiss in
            CellImageWindowContent(
                data: data,
                format: format,
                sourceKind: sourceKind,
                onDismiss: dismiss
            )
        }
    }
}

private struct CellImageWindowContent: View {
    let data: Data
    let format: CellImageFormat
    let sourceKind: CellImageSourceKind
    let onDismiss: () -> Void

    var body: some View {
        CellImageViewer(
            data: { data },
            format: format,
            sourceKind: sourceKind
        ) {
            source
        }
    }

    @ViewBuilder
    private var source: some View {
        switch sourceKind {
        case .markup:
            TextValueEditor(
                text: .constant(String(bytes: data, encoding: .utf8) ?? ""),
                isEditable: false,
                font: ThemeEngine.shared.valueFont
            )
        case .hex:
            HexEditorBody(
                initialValue: String(data: data, encoding: .isoLatin1),
                isEditable: false,
                onDismiss: onDismiss
            )
        }
    }
}
