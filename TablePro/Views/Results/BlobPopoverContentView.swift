//
//  BlobPopoverContentView.swift
//  TablePro
//

import SwiftUI

/// The popover a binary cell opens. Bytes that read as an image get the drawing first, with the hex
/// dump one segment away; everything else is the hex dump on its own, exactly as before.
internal struct BlobPopoverContentView: View {
    let initialValue: String?
    let image: CellImageValue?
    let columnName: String?
    let isEditable: Bool
    var onCommit: ((String) -> Void)?
    var onCommitBytes: ((Data) -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let image {
                CellImageViewer(
                    data: { image.data },
                    format: image.format,
                    sourceKind: .hex,
                    onPopOut: {
                        onDismiss()
                        CellImageWindowController.open(
                            data: image.data,
                            format: image.format,
                            sourceKind: .hex,
                            columnName: columnName
                        )
                    },
                    source: { hexEditor }
                )
            } else {
                hexEditor
            }
        }
        .frame(width: HexEditorMetrics.popoverWidth, height: isEditable ? 440 : 320)
    }

    private var hexEditor: some View {
        HexEditorBody(
            initialValue: initialValue,
            isEditable: isEditable,
            onCommit: onCommit ?? { _ in },
            onCommitBytes: onCommitBytes,
            onDismiss: onDismiss
        )
    }
}
