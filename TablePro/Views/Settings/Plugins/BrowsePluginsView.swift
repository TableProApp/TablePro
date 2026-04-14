//
//  BrowsePluginsView.swift
//  TablePro
//

import SwiftUI

struct BrowsePluginsView: View {
    private let registryClient = RegistryClient.shared
    private let pluginManager = PluginManager.shared
    private let installTracker = PluginInstallTracker.shared
    private let downloadCountService = DownloadCountService.shared

    @State private var searchText = ""
    @State private var selectedCategory: RegistryCategory?
    @State private var selectedPluginId: String?
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private var selectedRegistryPlugin: RegistryPlugin? {
        guard let selectedPluginId else { return nil }
        return registryClient.manifest?.plugins.first { $0.id == selectedPluginId }
    }

    var body: some View {
        mainContent
        .task {
            if registryClient.fetchState == .idle {
                await registryClient.fetchManifest()
            }
            await downloadCountService.fetchCounts(for: registryClient.manifest)
        }
        .alert(String(localized: "Installation Failed"), isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: searchText) {
            clearSelectionIfNeeded()
        }
        .onChange(of: selectedCategory) {
            clearSelectionIfNeeded()
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch registryClient.fetchState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            let plugins = registryClient.search(query: searchText, category: selectedCategory)
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $selectedCategory) {
                            Text("All").tag(RegistryCategory?.none)
                            ForEach(RegistryCategory.allCases) { category in
                                Text(category.displayName).tag(RegistryCategory?.some(category))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    if plugins.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(plugins, selection: $selectedPluginId) { plugin in
                            browseRow(plugin)
                                .tag(plugin.id)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)

                detailContent
                    .frame(minWidth: 340)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task {
                        await registryClient.fetchManifest(forceRefresh: true)
                        await downloadCountService.fetchCounts(for: registryClient.manifest)
                    }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Browse Row

    @ViewBuilder
    private func browseRow(_ plugin: RegistryPlugin) -> some View {
        HStack(spacing: 8) {
            PluginIconView(name: plugin.iconName ?? "puzzlepiece")
                .font(.title3)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(plugin.name)
                        .lineLimit(1)
                    if plugin.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.blue)
                            .font(.caption2)
                    }
                }

                HStack(spacing: 4) {
                    Text("v\(plugin.version)")
                    Text("·")
                    Text(plugin.author.name)
                        .lineLimit(1)
                    if let count = downloadCountService.downloadCount(for: plugin.id) {
                        Text("·")
                        Text("\(Image(systemName: "arrow.down.circle")) \(formattedCount(count))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            rowStatusBadge(for: plugin)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Row Status Badge

    @ViewBuilder
    private func rowStatusBadge(for plugin: RegistryPlugin) -> some View {
        if isPluginInstalled(plugin.id) {
            Text("Installed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let progress = installTracker.state(for: plugin.id) {
            switch progress.phase {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 40)
                    .progressViewStyle(.linear)
            case .installing:
                ProgressView()
                    .controlSize(.mini)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .font(.caption)
            case .failed:
                Button("Retry") { installPlugin(plugin) }
                    .controlSize(.mini)
            }
        } else {
            Button("Install") { installPlugin(plugin) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
    }

    private func formattedCount(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let selectedPlugin = selectedRegistryPlugin {
            RegistryPluginDetailView(
                plugin: selectedPlugin,
                isInstalled: isPluginInstalled(selectedPlugin.id),
                installProgress: installTracker.state(for: selectedPlugin.id),
                downloadCount: downloadCountService.downloadCount(for: selectedPlugin.id),
                onInstall: { installPlugin(selectedPlugin) }
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a plugin to view details")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private func isPluginInstalled(_ pluginId: String) -> Bool {
        pluginManager.plugins.contains { $0.id == pluginId }
            || ThemeRegistryInstaller.shared.isInstalled(pluginId)
    }

    private func installPlugin(_ plugin: RegistryPlugin) {
        Task {
            installTracker.beginInstall(pluginId: plugin.id)
            do {
                if plugin.category == .theme {
                    try await ThemeRegistryInstaller.shared.install(plugin) { fraction in
                        installTracker.updateProgress(pluginId: plugin.id, fraction: fraction)
                        if fraction >= 1.0 {
                            installTracker.markInstalling(pluginId: plugin.id)
                        }
                    }
                } else {
                    _ = try await pluginManager.installFromRegistry(plugin) { fraction in
                        installTracker.updateProgress(pluginId: plugin.id, fraction: fraction)
                        if fraction >= 1.0 {
                            installTracker.markInstalling(pluginId: plugin.id)
                        }
                    }
                }
                installTracker.completeInstall(pluginId: plugin.id)
            } catch {
                installTracker.failInstall(pluginId: plugin.id, error: error.localizedDescription)
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func clearSelectionIfNeeded() {
        guard let selectedPluginId else { return }
        let plugins = registryClient.search(query: searchText, category: selectedCategory)
        if !plugins.contains(where: { $0.id == selectedPluginId }) {
            self.selectedPluginId = nil
        }
    }
}
