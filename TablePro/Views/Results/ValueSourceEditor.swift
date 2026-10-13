//
//  ValueSourceEditor.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct ValueSourceEditor: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Binding var text: String
    var isEditable: Bool
    var textContainerInset = NSSize(width: 4, height: 6)

    internal var body: some View {
        TextValueEditor(
            text: $text,
            isEditable: isEditable,
            font: themeEngine.valueFont,
            textContainerInset: textContainerInset,
            style: .code
        )
    }
}
