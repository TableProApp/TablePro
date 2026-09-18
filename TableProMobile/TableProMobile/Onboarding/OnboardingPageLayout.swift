import SwiftUI
import UIKit

struct OnboardingPageLayout<Header: View, Content: View, Actions: View>: View {
    private static var readableWidth: CGFloat { 560 }

    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        scrollContent.bottomSafeAreaBar(spacing: nil) { actionBar }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 32) {
                header
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var actionBar: some View {
        if Actions.self != EmptyView.self {
            VStack(spacing: 12) {
                actions
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

struct OnboardingHeader: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource?
    let image: OnboardingHeaderImage

    var body: some View {
        VStack(spacing: 16) {
            switch image {
            case .appIcon:
                AppIconImage()
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

enum OnboardingHeaderImage {
    case appIcon
    case symbol(String)
}

struct FeatureHighlightList: View {
    let highlights: [FeatureHighlight]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(highlights) { highlight in
                FeatureHighlightRow(highlight: highlight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FeatureHighlightRow: View {
    let highlight: FeatureHighlight

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var symbolWidth: CGFloat = 40

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    }

    var body: some View {
        layout {
            Image(systemName: highlight.systemImage)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title)
                    .font(.headline)
                Text(highlight.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AppIconImage: View {
    @ScaledMetric(relativeTo: .largeTitle) private var side: CGFloat = 88

    var body: some View {
        Group {
            if let icon = Self.primaryIcon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                Image(systemName: "cylinder.split.1x2")
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.2)
                    .foregroundStyle(.tint)
                    .background(.fill.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }

    private static var primaryIcon: UIImage? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }
}
