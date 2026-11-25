import SwiftUI

struct OnboardingChoiceCard: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OnboardingChoiceCardLabel(title: title, detail: detail, systemImage: systemImage)
        }
        .buttonStyle(OnboardingChoiceCardStyle())
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
    }
}

private struct OnboardingChoiceCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingChoiceCardBody(configuration: configuration)
    }
}

private struct OnboardingChoiceCardBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.5)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: shape)
            .overlay {
                shape
                    .fill(.fill.tertiary)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .contentShape(shape)
            .contentShape(.hoverEffect, shape)
    }
}

private struct OnboardingChoiceCardLabel: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var symbolSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var symbolFrame: CGFloat = 36

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        layout {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: symbolFrame, height: symbolFrame)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}
