//
//  ValueWell.swift
//  TablePro
//

import SwiftUI

internal extension View {
    /// The rounded, bordered well a stored value sits in, on the editor's background while the active
    /// theme sets it. `clipsContent` is for a view that paints its own background, which the well
    /// clips to its corners; text drawn straight on the well gets the text background instead.
    func valueWell(clipsContent: Bool = false) -> some View {
        modifier(ValueWell(clipsContent: clipsContent))
    }
}

private struct ValueWell: ViewModifier {
    let clipsContent: Bool

    private static let shape = RoundedRectangle(cornerRadius: 5)

    @ViewBuilder
    func body(content: Content) -> some View {
        if clipsContent {
            content
                .themeBackground(.editorBackground, native: Color.clear, in: Self.shape)
                .clipShape(Self.shape)
                .overlay(Self.border)
        } else {
            content
                .themeBackground(.editorBackground, native: Color(nsColor: .textBackgroundColor), in: Self.shape)
                .overlay(Self.border)
        }
    }

    private static var border: some View {
        shape.strokeBorder(Color(nsColor: .separatorColor))
    }
}
