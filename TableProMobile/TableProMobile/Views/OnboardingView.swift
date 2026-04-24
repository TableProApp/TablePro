//
//  OnboardingView.swift
//  TableProMobile
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentPage = 0
    @State private var showAddConnection = false
    @State private var didAddConnection = false
    @State private var isSyncing = false
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $currentPage) {
            welcomePage.tag(0)
            getStartedPage.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .sheet(isPresented: $showAddConnection, onDismiss: {
            if didAddConnection {
                completeOnboarding()
            }
        }) {
            ConnectionFormView { connection in
                appState.addConnection(connection)
                didAddConnection = true
                showAddConnection = false
            }
        }
        .overlay {
            if isSyncing {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Syncing from iCloud...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .allowsHitTesting(!isSyncing)
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()

            appIconImage
                .padding(.bottom, 24)

            Text("Welcome to TablePro")
                .font(.largeTitle.bold())
                .padding(.bottom, 12)

            Text("A fast, lightweight database client for your iPhone and iPad.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                withAnimation { currentPage = 1 }
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 60)
        }
    }

    private var getStartedPage: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Get Started")
                .font(.title.bold())
                .padding(.bottom, 32)

            VStack(spacing: 12) {
                Button(action: syncFromiCloud) {
                    actionCard(
                        icon: "icloud.and.arrow.down",
                        color: .blue,
                        title: String(localized: "Sync from iCloud"),
                        description: String(localized: "Import connections from your Mac")
                    )
                }

                Button(action: addNewConnection) {
                    actionCard(
                        icon: "plus.circle.fill",
                        color: .green,
                        title: String(localized: "Add Connection"),
                        description: String(localized: "Set up a new database connection")
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            Button("Skip", action: completeOnboarding)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 60)
        }
    }

    // MARK: - Components

    private var appIconImage: some View {
        Group {
            if let uiImage = Self.loadAppIcon() {
                Image(uiImage: uiImage)
                    .resizable()
            } else {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func actionCard(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func syncFromiCloud() {
        isSyncing = true
        syncTask = Task {
            await appState.syncCoordinator.sync(
                localConnections: appState.connections,
                localGroups: appState.groups,
                localTags: appState.tags
            )
            guard !Task.isCancelled else { return }
            isSyncing = false
            completeOnboarding()
        }
    }

    private func addNewConnection() {
        didAddConnection = false
        showAddConnection = true
    }

    private func completeOnboarding() {
        appState.hasCompletedOnboarding = true
    }

    // MARK: - Helpers

    private static func loadAppIcon() -> UIImage? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }
}
