//
//  ConnectionColorPicker.swift
//  TablePro
//
//  Created by Claude on 20/12/25.
//

import SwiftUI

/// A horizontal color palette picker for connection colors
struct ConnectionColorPicker: View {
    @Binding var selectedColor: ConnectionColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ConnectionColor.allCases) { color in
                Button(action: { selectedColor = color }) {
                    ColorDot(
                        color: color,
                        isSelected: selectedColor == color
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Color \(color.rawValue)"))
            }
        }
    }
}

// MARK: - Color Dot

private struct ColorDot: View {
    let color: ConnectionColor
    let isSelected: Bool

    var body: some View {
        ZStack {
            if color == .none {
                // "None" option - shows as crossed circle
                Circle()
                    .stroke(Color.secondary, lineWidth: 1)
                    .frame(width: ThemeEngine.shared.activeTheme.iconSizes.large, height: ThemeEngine.shared.activeTheme.iconSizes.large)
                Image(systemName: "circle.slash")
                    .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.small))
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(color.color)
                    .frame(width: ThemeEngine.shared.activeTheme.iconSizes.large, height: ThemeEngine.shared.activeTheme.iconSizes.large)
            }

            if isSelected {
                Circle()
                    .stroke(Color.primary, lineWidth: 2)
                    .frame(width: ThemeEngine.shared.activeTheme.iconSizes.extraLarge, height: ThemeEngine.shared.activeTheme.iconSizes.extraLarge)
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
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
