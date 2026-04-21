//
//  JSONEditorContentView.swift
//  TablePro
//

import SwiftUI

struct JSONEditorContentView: View {
    let initialValue: String?
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text: String

    init(
        initialValue: String?,
        onCommit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialValue = initialValue
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._text = State(initialValue: initialValue?.prettyPrintedAsJson() ?? initialValue ?? "")
    }

    var body: some View {
        JSONViewerView(
            text: $text,
            isEditable: true,
            onDismiss: onDismiss,
            onCommit: { newValue in
                if newValue != initialValue {
                    onCommit(newValue)
                }
            }
        )
        .frame(width: 560, height: 480)
    }
}
