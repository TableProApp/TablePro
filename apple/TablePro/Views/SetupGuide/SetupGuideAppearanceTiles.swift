import AppKit
import SwiftUI

internal struct SetupGuideAppearanceTiles: View {
    @Binding var mode: AppAppearanceMode

    @FocusState private var focused: AppAppearanceMode?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(AppAppearanceMode.choices, id: \.self) { choice in
                tile(choice)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Appearance"))
        .accessibilityIdentifier("appearance-mode-picker")
        .modifier(SetupGuideArrowKeys(move: move))
    }

    private func tile(_ choice: AppAppearanceMode) -> some View {
        let isSelected = mode == choice
        return Button {
            select(choice)
        } label: {
            Text(verbatim: choice.title)
        }
        .buttonStyle(AppearanceTileStyle(mode: choice, isSelected: isSelected))
        .focused($focused, equals: choice)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("appearance-mode-\(choice.rawValue)")
    }

    private func select(_ choice: AppAppearanceMode) {
        guard choice != mode else { return }
        mode = choice
    }

    private func move(_ direction: SetupGuideArrowKeys.Direction) -> Bool {
        guard direction == .left || direction == .right else { return false }
        let choices = AppAppearanceMode.choices
        guard let index = choices.firstIndex(of: focused ?? mode) else { return false }
        let next = choices[min(max(index + (direction == .left ? -1 : 1), 0), choices.count - 1)]
        select(next)
        focused = next
        return true
    }
}

private struct AppearanceTileStyle: ButtonStyle {
    let mode: AppAppearanceMode
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        AppearanceTile(configuration: configuration, mode: mode, isSelected: isSelected)
    }
}

private struct AppearanceTile: View {
    let configuration: ButtonStyleConfiguration
    let mode: AppAppearanceMode
    let isSelected: Bool

    @State private var isHovered = false

    private static let ring = RoundedRectangle(cornerRadius: 11, style: .continuous)

    var body: some View {
        VStack(spacing: 8) {
            AppearanceThumbnail(mode: mode)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .overlay {
                    Self.ring
                        .strokeBorder(.tint, lineWidth: 3)
                        .padding(-4)
                        .opacity(isSelected ? 1 : 0)
                        .motionAnimation(.easeInOut(duration: 0.12), value: isSelected)
                }
                .overlay {
                    if isHovered, !isSelected {
                        Self.ring
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            .padding(-4)
                    }
                }
            configuration.label
                .font(isSelected ? .callout.weight(.semibold) : .callout)
        }
        .contentShape(Rectangle())
        .contentShape(.focusEffect, Self.ring)
        .onHover { isHovered = $0 }
    }
}

// A small window drawn in the scheme it stands for, so each tile previews its mode whatever the guide's own.
private struct AppearanceThumbnail: View {
    let mode: AppAppearanceMode

    private static let size = CGSize(width: 104, height: 66)
    private static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Group {
            switch mode {
            case .light:
                window(.light)
            case .dark:
                window(.dark)
            case .auto:
                window(.light)
                    .overlay {
                        window(.dark)
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: Self.size.width / 2)
                            }
                    }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(Self.shape)
        .overlay {
            Self.shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func window(_ scheme: ColorScheme) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(quaternaryFill)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(.tint)
                    .frame(width: 34, height: 5)
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 52, height: 4)
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 40, height: 4)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tertiaryFill)
                    .frame(height: 16)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.background)
        .environment(\.colorScheme, scheme)
    }

    private var quaternaryFill: AnyShapeStyle {
        if #available(macOS 14.0, *) {
            return AnyShapeStyle(.fill.quaternary)
        }
        return AnyShapeStyle(Color.primary.opacity(0.05))
    }

    private var tertiaryFill: AnyShapeStyle {
        if #available(macOS 14.0, *) {
            return AnyShapeStyle(.fill.tertiary)
        }
        return AnyShapeStyle(Color.primary.opacity(0.08))
    }
}
