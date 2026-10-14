//
//  CodeWell.swift
//  TablePro
//

import SwiftUI

/// Read-only code or a stored value in a rounded well, with selectable text that scrolls sideways
/// rather than wrap. It wears the editor's background and text while the active theme sets them.
internal struct CodeWell: View {
    private let text: String
    private let font: Font

    private static let shape = RoundedRectangle(cornerRadius: 6)

    internal init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    internal var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(font)
                .themeForeground(.editorText, native: .primary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .themeBackground(.editorBackground, native: Color(nsColor: .textBackgroundColor), in: Self.shape)
        .overlay(Self.shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
