import CloudKit
import SwiftUI

struct FirstRunSheet: View {
    let pages: [FirstRunPage]

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FirstRunPage] = []
    @State private var isAdvancing = false

    var body: some View {
        NavigationStack(path: $path) {
            page(pages.first ?? .usageData)
                .navigationDestination(for: FirstRunPage.self) { page($0) }
        }
    }

    @ViewBuilder
    private func page(_ page: FirstRunPage) -> some View {
        switch page {
        case .welcome:
            WelcomePage(isAdvancing: isAdvancing) {
                advance(from: .welcome)
            }
            .toolbar(.hidden, for: .navigationBar)
        case .iCloud:
            ICloudPage(
                onUse: {
                    appState.setCloudSyncEnabled(true)
                    advance(from: .iCloud)
                },
                onNotNow: {
                    appState.setCloudSyncEnabled(false)
                    advance(from: .iCloud)
                }
            )
            .navigationBarTitleDisplayMode(.inline)
        case .usageData:
            UsageDataPage(
                onShare: {
                    appState.setUsageDataEnabled(true)
                    advance(from: .usageData)
                },
                onDontShare: {
                    appState.setUsageDataEnabled(false)
                    advance(from: .usageData)
                }
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func advance(from current: FirstRunPage) {
        guard !isAdvancing else { return }
        isAdvancing = true
        Task {
            defer { isAdvancing = false }
            guard let next = await nextPage(after: current) else {
                dismiss()
                return
            }
            path.append(next)
        }
    }

    private func nextPage(after current: FirstRunPage) async -> FirstRunPage? {
        guard let index = pages.firstIndex(of: current) else { return nil }
        for candidate in pages.dropFirst(index + 1) {
            if candidate == .iCloud, await !isICloudAvailable() {
                continue
            }
            return candidate
        }
        return nil
    }

    private func isICloudAvailable() async -> Bool {
        await appState.syncCoordinator.accountStatus() == .available
    }
}

private struct WelcomePage: View {
    let isAdvancing: Bool
    let onContinue: () -> Void

    var body: some View {
        OnboardingPageLayout {
            OnboardingHeader(title: "Welcome to TablePro", message: nil, image: .appIcon)
        } content: {
            FeatureHighlightList(highlights: FeatureHighlights.welcome)
        } actions: {
            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAdvancing)
            .accessibilityIdentifier("first-run-continue")
        }
    }
}

private struct ICloudPage: View {
    let onUse: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        OnboardingPageLayout {
            OnboardingHeader(
                title: "Sync with iCloud",
                message: "Keep your connections, groups, and tags the same on your iPhone, iPad, and Mac.",
                image: .symbol("icloud")
            )
        } content: {
            Text("Passwords stay on this device unless you turn on Sync Passwords in Settings. You can change this at any time in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } actions: {
            Button(action: onUse) {
                Text("Use iCloud")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("first-run-use-icloud")
            Button("Not Now", action: onNotNow)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("first-run-icloud-not-now")
        }
    }
}

private struct UsageDataPage: View {
    let onShare: () -> Void
    let onDontShare: () -> Void

    var body: some View {
        OnboardingPageLayout {
            OnboardingHeader(
                title: "Share Usage Data?",
                message: "Help decide what to improve next by sending one small report a day.",
                image: .symbol("chart.bar.xaxis")
            )
        } content: {
            UsageDataDisclosure()
        } actions: {
            Button(action: onShare) {
                Text("Share Usage Data")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("first-run-share-usage")
            Button("Don't Share", action: onDontShare)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("first-run-dont-share-usage")
        }
    }
}

struct UsageDataDisclosure: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The report contains:")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("A hashed identifier for this device", systemImage: "number")
                Label("The app and iOS versions, and your language", systemImage: "info.circle")
                Label("Which database types you connect to, and how many connections are open", systemImage: "cylinder")
                Label("When you first connected and first ran a query", systemImage: "calendar")
            }
            .font(.subheadline)
            Text("It never contains a hostname, username, password, query, or any data from your databases. You can change this in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
