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
            page(pages.first ?? .welcome)
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
                message: "Keep your connections, groups, tags, and saved queries the same on your iPhone, iPad, and Mac.",
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
