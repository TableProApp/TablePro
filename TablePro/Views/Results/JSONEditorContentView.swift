//
//  JSONEditorContentView.swift
//  TablePro
//

import SwiftUI

struct JSONEditorContentView: View {
    let initialValue: String?
    let columnName: String?
    let onCommit: (String) -> Void
    let onDismiss: () -> Void
    var onPopOut: ((String) -> Void)?

    @State private var text: String

    init(
        initialValue: String?,
        columnName: String? = nil,
        onCommit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void,
        onPopOut: ((String) -> Void)? = nil
    ) {
        self.initialValue = initialValue
        self.columnName = columnName
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self.onPopOut = onPopOut
        self._text = State(initialValue: initialValue?.prettyPrintedAsJson() ?? initialValue ?? "")
    }

    var body: some View {
        JSONViewerView(
            text: $text,
            isEditable: true,
            onDismiss: onDismiss,
            onCommit: { newValue in
                if newValue.isEmpty && initialValue == nil { return }
                let normalizedNew = JSONViewerView.compact(newValue)
                let normalizedOld = JSONViewerView.compact(initialValue)
                if normalizedNew != normalizedOld {
                    onCommit(newValue)
                }
            },
            onPopOut: onPopOut
        )
        .frame(width: 560)
        .frame(minHeight: 200, maxHeight: 480)
    }
}
