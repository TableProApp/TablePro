//
//  PhpSerializedFieldView.swift
//  TablePro
//

import SwiftUI

internal struct PhpSerializedFieldView: View {
    let context: FieldEditorContext
    var onExpand: (() -> Void)?
    var onPopOut: ((String) -> Void)?

    var body: some View {
        PhpViewerView(
            rawValue: context.value.wrappedValue,
            onPopOut: onPopOut
        )
        .frame(minHeight: 80, maxHeight: 200)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        .overlay(alignment: .bottomTrailing) {
            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .padding(4)
                        .themeMaterial(.inlineControl, .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Expand in Sidebar"))
                .padding(4)
            }
        }
    }
}
