//
//  ConnectionColorPicker.swift
//  TablePro
//

import SwiftUI

/// Color picker for the per-connection color selector. Includes "None".
struct ConnectionColorPicker: View {
    @Binding var selectedColor: ConnectionColor

    var body: some View {
        ColorPaletteView(selectedColor: $selectedColor, includesNone: true, size: .regular)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var color: ConnectionColor = .none

        var body: some View {
            VStack(spacing: 20) {
                ConnectionColorPicker(selectedColor: $color)
                Text("Selected: \(color.rawValue)")
            }
            .padding()
        }
    }

    return PreviewWrapper()
}
