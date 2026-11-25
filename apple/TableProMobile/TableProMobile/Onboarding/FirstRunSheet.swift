import CloudKit
import SwiftUI

struct FirstRunSheet: View {
    let pages: [FirstRunPage]
    let onStart: (LibraryStartAction) -> Void

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
        case .origin:
            OriginPage(
                offersICloud: !appState.onboarding.isCloudSyncEnabled,
                isAdvancing: isAdvancing,
                onChoose: choose,
                onSkip: { advance(from: .origin) }
            )
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

    // Sync is the iCloud page's own question, so the card answers it here and that page is skipped.
    private func choose(_ action: LibraryStartAction) {
        guard !isAdvancing else { return }
        if action == .turnOnICloud {
            appState.setCloudSyncEnabled(true)
        }
        onStart(action)
        advance(from: .origin)
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
            if candidate == .iCloud, appState.onboarding.syncChoice != nil {
                continue
            }
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

private struct OriginPage: View {
    let offersICloud: Bool
    let isAdvancing: Bool
    let onChoose: (LibraryStartAction) -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingPageLayout {
            OnboardingHeader(
                title: "Welcome to TablePro",
                message: "Bring your connections, or start with a new one.",
                image: .appIcon
            )
        } content: {
            VStack(alignment: .leading, spacing: 28) {
                group(
                    "Bring Your Connections",
                    footer: "Using another app? Import its connections in TablePro on your Mac, then sync them here with iCloud."
                ) {
                    if offersICloud {
                        card(.turnOnICloud, detail: "Connections from TablePro on your Mac appear here.")
                    }
                    card(.importConnections, detail: "A .tablepro file from AirDrop, Files, or Mail.")
                }
                group("Start Fresh") {
                    card(.addConnection, detail: "Enter the server details yourself.")
                    card(.openSample, detail: "Explore a music store database without connecting to a server.")
                }
            }
            .disabled(isAdvancing)
        } actions: {
            Button("Skip", action: onSkip)
                .buttonStyle(.borderless)
                .disabled(isAdvancing)
                .accessibilityIdentifier("first-run-origin-skip")
        }
    }

    private func group<Cards: View>(
        _ title: LocalizedStringResource,
        footer: LocalizedStringResource? = nil,
        @ViewBuilder cards: () -> Cards
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 10) {
                cards()
            }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ action: LibraryStartAction, detail: LocalizedStringResource) -> some View {
        OnboardingChoiceCard(title: action.title, detail: detail, systemImage: action.systemImage) {
            onChoose(action)
        }
        .accessibilityIdentifier("first-run-origin-\(action.accessibilityIdentifier)")
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
            Button("Use iCloud", action: onUse)
                .onboardingProminentButton()
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
                message: "Help decide what to improve next. Nothing is sent unless you choose Share Usage Data.",
                image: .symbol("chart.bar.xaxis")
            )
        } content: {
            UsageDataDisclosure()
        } actions: {
            Button("Share Usage Data", action: onShare)
                .onboardingProminentButton()
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
            Text("Sent to PostHog:")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("A random identifier for this install", systemImage: "number")
                Label("The app and iOS versions, device model, screen size, language, time zone, and network type", systemImage: "info.circle")
                Label("Which database types you connect to, and how many connections are open", systemImage: "cylinder")
                Label("When you first connect and first run a query", systemImage: "calendar")
            }
            .font(.subheadline)
            Text("PostHog derives an approximate location from your IP address. Nothing sent contains a hostname, username, password, query, or any data from your databases. You can change this in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
