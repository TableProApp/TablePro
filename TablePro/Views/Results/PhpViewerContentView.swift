//
//  PhpViewerContentView.swift
//  TablePro
//

import SwiftUI

struct PhpViewerContentView: View {
    let initialValue: String?
    let columnName: String?
    let onDismiss: () -> Void
    var onPopOut: ((String) -> Void)?

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
    }

    var body: some View {
        PhpViewerView(
            rawValue: initialValue ?? "",
            onDismiss: onDismiss,
            onPopOut: onPopOut
        )
        .frame(width: 560)
        .frame(minHeight: 200, maxHeight: 480)
    }
}
