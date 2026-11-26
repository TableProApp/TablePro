import AppKit
import SwiftUI

internal enum SetupGuideCardSize {
    case row
    case compact

    var cornerRadius: CGFloat {
        switch self {
        case .row: 12
        case .compact: 10
        }
    }

    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

internal struct SetupGuideCardBackground: ViewModifier {
    var size: SetupGuideCardSize = .row
    var isSelected = false
    var isHovered = false
    var isPressed = false

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = size.shape
        content
            .background { fill(in: shape) }
            .overlay {
                shape
                    .strokeBorder(.tint, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
                    .motionAnimation(.easeInOut(duration: 0.12), value: isSelected)
            }
            .overlay {
                if contrast == .increased, !isSelected {
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
    }

    @ViewBuilder
    private func fill(in shape: RoundedRectangle) -> some View {
        if #available(macOS 14.0, *) {
            if isPressed {
                shape.fill(.fill.secondary)
            } else if isHovered {
                shape.fill(.fill.tertiary)
            } else {
                shape.fill(.fill.quaternary)
            }
        } else {
            shape.fill(Color.primary.opacity(isPressed ? 0.12 : isHovered ? 0.08 : 0.05))
        }
    }
}

internal struct SetupGuideCardIndicator: View {
    enum Kind {
        case single
        case multiple
    }

    let kind: Kind
    let isOn: Bool
    var size: SetupGuideCardSize = .row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch (kind, isOn) {
        case (.single, true): "checkmark.circle.fill"
        case (.single, false): "circle"
        case (.multiple, true): "checkmark.square.fill"
        case (.multiple, false): "square"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(size == .row ? .title3 : .body)
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .modifier(SymbolReplaceTransition(isActive: !reduceMotion))
            .motionAnimation(.easeInOut(duration: 0.12), value: isOn)
            .accessibilityHidden(true)
    }
}

private struct SymbolReplaceTransition: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *), isActive {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}

internal struct SetupGuideChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool
    var size: SetupGuideCardSize = .row

    func makeBody(configuration: Configuration) -> some View {
        SetupGuideChoiceCard(configuration: configuration, isSelected: isSelected, size: size)
    }
}

private struct SetupGuideChoiceCard: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let size: SetupGuideCardSize

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            SetupGuideCardIndicator(kind: .single, isOn: isSelected, size: size)
        }
        .padding(.horizontal, size == .row ? 16 : 12)
        .padding(.vertical, size == .row ? 12 : 10)
        .frame(maxWidth: .infinity, minHeight: size == .row ? 60 : 40, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.5)
        .modifier(SetupGuideCardBackground(
            size: size,
            isSelected: isSelected,
            isHovered: isHovered,
            isPressed: configuration.isPressed
        ))
        .onHover { isHovered = $0 }
    }
}

// A multi-select card's top, padding included so all of it ticks; the card draws the fill, so the press goes up.
internal struct SetupGuideCardToggleStyle: ToggleStyle {
    var showsIndicator = true
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        SetupGuideToggleCardTop(configuration: configuration, showsIndicator: showsIndicator, isPressed: $isPressed)
    }
}

private struct SetupGuideToggleCardTop: View {
    let configuration: ToggleStyleConfiguration
    let showsIndicator: Bool
    @Binding var isPressed: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                if showsIndicator {
                    SetupGuideCardIndicator(kind: .multiple, isOn: configuration.isOn)
                        .opacity(isEnabled ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, configuration.isOn ? 10 : 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressReportingButtonStyle(isPressed: $isPressed))
        .contentShape(.focusEffect, SetupGuideCardSize.row.shape)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.checkbox)
        }
    }
}

private struct PressReportingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onValueChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

internal struct SetupGuideCardLabel: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

internal struct SetupGuideCompactCardLabel: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.body)
                .lineLimit(1)
        }
    }
}

internal struct SetupGuideSettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SetupGuideCardBackground())
    }
}

// macOS 13 has no key press handler, so there Tab is the only way between cards.
internal struct SetupGuideArrowKeys: ViewModifier {
    enum Direction {
        case up
        case down
        case left
        case right
    }

    let move: @MainActor (Direction) -> Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                let direction: Direction? = switch press.key {
                case .upArrow: .up
                case .downArrow: .down
                case .leftArrow: .left
                case .rightArrow: .right
                default: nil
                }
                guard let direction, move(direction) else { return .ignored }
                return .handled
            }
        } else {
            content
        }
    }
}
