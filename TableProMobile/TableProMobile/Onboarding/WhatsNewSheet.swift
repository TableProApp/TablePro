import SwiftUI

struct WhatsNewSheet: View {
    let version: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WhatsNewContent(version: version) {
                Button {
                    dismiss()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct WhatsNewContent<Actions: View>: View {
    let version: String
    @ViewBuilder let actions: Actions

    var body: some View {
        OnboardingPageLayout {
            OnboardingHeader(
                title: "What's New in TablePro",
                message: LocalizedStringResource("Version \(version)"),
                image: .appIcon
            )
        } content: {
            FeatureHighlightList(highlights: FeatureHighlights.release(version) ?? [])
        } actions: {
            actions
        }
    }
}

struct WhatsNewSettingsPage: View {
    let version: String

    var body: some View {
        WhatsNewContent(version: version) {
            EmptyView()
        }
        .navigationTitle(Text("What's New"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
