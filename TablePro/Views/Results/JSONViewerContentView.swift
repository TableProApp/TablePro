//
//  JSONViewerContentView.swift
//  TablePro
//

import SwiftUI

struct JSONViewerContentView: View {
    let initialValue: String?
    let columnName: String?
    let onDismiss: () -> Void
    var onPopOut: ((String) -> Void)?

    @State private var text: String

    init(
        initialValue: String?,
        columnName: String? = nil,
        onDismiss: @escaping () -> Void,
        onPopOut: ((String) -> Void)? = nil
    ) {
        self.initialValue = initialValue
        self.columnName = columnName
        self.onDismiss = onDismiss
        self.onPopOut = onPopOut
        self._text = State(initialValue: initialValue ?? "")
    }

    var body: some View {
        JSONViewerView(
            text: $text,
            isEditable: false,
            onDismiss: onDismiss,
            onPopOut: onPopOut
        )
        .frame(width: 560)
        .frame(minHeight: 200, maxHeight: 480)
    }
}
