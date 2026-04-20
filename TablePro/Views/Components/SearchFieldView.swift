//
//  SearchFieldView.swift
//  TablePro
//

import SwiftUI

struct SearchFieldView: View {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat?

    var body: some View {
        let resolvedSize = fontSize ?? 13
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: resolvedSize))
                .foregroundStyle(.tertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: resolvedSize))

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
