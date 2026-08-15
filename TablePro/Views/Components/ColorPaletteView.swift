//
//  ColorPaletteView.swift
//  TablePro
//

import SwiftUI

struct ColorPaletteView: View {
    @Binding var selectedColor: ConnectionColor
    var includesNone: Bool
    var size: Size

    enum Size {
        case compact, regular

        var dotSize: CGFloat { self == .compact ? 16 : 20 }
        var frameSize: CGFloat { self == .compact ? 20 : 28 }
        var spacing: CGFloat { self == .compact ? 6 : 8 }
        var selectionRingSize: CGFloat { self == .compact ? 20 : 24 }
    }

    init(
        selectedColor: Binding<ConnectionColor>,
        includesNone: Bool = true,
        size: Size = .regular
    ) {
        _selectedColor = selectedColor
        self.includesNone = includesNone
        self.size = size
    }

    private var colors: [ConnectionColor] {
        includesNone ? ConnectionColor.allCases : ConnectionColor.allCases.filter { $0 != .none }
    }

    var body: some View {
        HStack(spacing: size.spacing) {
            ForEach(colors) { color in
                let isSelected = selectedColor == color
                Button { selectedColor = color } label: {
                    ColorSwatch(color: color, isSelected: isSelected, size: size)
                }
                .buttonStyle(ColorSwatchButtonStyle())
                .focusable()
                .accessibilityLabel(String(format: String(localized: "Color %@"), color.rawValue))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

/// A swatch is a control, so it has to answer the pointer and the click the way one does. A plain
/// button style suppresses every built-in state, which left these with no press and no hover.
private struct ColorSwatchButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .background(
                Circle()
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .opacity(isHovering && !configuration.isPressed ? 1 : 0)
            )
            .onHover { isHovering = $0 }
            .motionAnimation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ColorSwatch: View {
    let color: ConnectionColor
    let isSelected: Bool
    let size: ColorPaletteView.Size

    var body: some View {
        ZStack {
            if color == .none {
                Circle()
                    .stroke(Color.secondary, lineWidth: 1)
                    .frame(width: size.dotSize, height: size.dotSize)
                Image(systemName: "circle.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(color.color)
                    .frame(width: size.dotSize, height: size.dotSize)
            }

            /// The ring is the only thing that says which swatch is picked, so it cannot be drawn
            /// in a colour the user configures. On a yellow or green accent it measured 1.32:1
            /// against the sheet; the label colour holds 12.49:1 whatever the accent is.
            if isSelected {
                Circle()
                    .stroke(Color.primary, lineWidth: 2)
                    .frame(width: size.selectionRingSize, height: size.selectionRingSize)
            }
        }
        .frame(width: size.frameSize, height: size.frameSize)
        .contentShape(Rectangle())
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var color: ConnectionColor = .none
        var body: some View {
            VStack(spacing: 20) {
                ColorPaletteView(selectedColor: $color, size: .regular)
                ColorPaletteView(selectedColor: $color, includesNone: false, size: .compact)
            }
            .padding()
        }
    }
    return PreviewWrapper()
}
