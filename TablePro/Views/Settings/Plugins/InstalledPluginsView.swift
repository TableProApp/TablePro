//
//  InstalledPluginsView.swift
//  TablePro

import AppKit
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct InstalledPluginsView: View {
    private let pluginManager = PluginManager.shared
    private let registryClient = RegistryClient.shared
    private let installTracker = PluginInstallTracker.shared

    @State private var selectedPluginId: String?
    @State private var searchText = ""
    @State private var showErrorAlert = false
    @State private var errorAlertTitle = ""
    @State private var errorAlertMessage = ""
    @State private var dismissedRestartBanner = false

    private var filteredPlugins: [PluginEntry] {
        if searchText.isEmpty { return pluginManager.plugins }
        return pluginManager.plugins.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if pluginManager.needsRestart && !dismissedRestartBanner {
                restartBanner
            }

            HSplitView {
                pluginList
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)

                detailPane
                    .frame(minWidth: 340)
            }
        }
        .task {
            if registryClient.fetchState == .idle {
                await registryClient.fetchManifest()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first,
                  provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                return false
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard ext == "zip" || ext == "tableplugin" else { return }
                Task {
                    installPlugin(from: url)
                }
            }
            return true
        }
        .alert(errorAlertTitle, isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorAlertMessage)
        }
    }

    // MARK: - Restart Banner

    private var restartBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text("Restart TablePro to fully unload removed plugins.")
                .font(.callout)
            Spacer()
            Button("Dismiss") { dismissedRestartBanner = true }
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Plugin List

    private var pluginList: some View {
        VStack(spacing: 0) {
            TextField("Filter...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            List(selection: $selectedPluginId) {
                ForEach(filteredPlugins) { plugin in
                    pluginRow(plugin)
                        .tag(plugin.id)
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                listBottomBar
            }
        }
        .onChange(of: searchText) {
            if let selectedPluginId, !filteredPlugins.contains(where: { $0.id == selectedPluginId }) {
                self.selectedPluginId = nil
            }
        }
    }

    private var listBottomBar: some View {
        HStack(spacing: 4) {
            Button {
                installFromFile()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(pluginManager.isInstalling)
            .accessibilityLabel(String(localized: "Install plugin from file"))

            Button {
                if let plugin = selectedPlugin {
                    uninstallPlugin(plugin)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selectedPlugin == nil || selectedPlugin?.source == .builtIn)
            .accessibilityLabel(
                selectedPlugin.map { String(format: String(localized: "Uninstall %@"), $0.name) }
                    ?? String(localized: "Uninstall plugin")
            )

            Spacer()

            if pluginManager.isInstalling {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Plugin Row

    @ViewBuilder
    private func pluginRow(_ plugin: PluginEntry) -> some View {
        HStack(spacing: 8) {
            PluginIconView(name: plugin.pluginIconName)
                .font(.title3)
                .frame(width: 24, height: 24)
                .foregroundStyle(plugin.isEnabled ? .secondary : .tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .lineLimit(1)
                    .foregroundStyle(plugin.isEnabled ? .primary : .secondary)

                HStack(spacing: 4) {
                    Text("v\(plugin.version)")
                    if let capability = plugin.capabilities.first {
                        Text("·")
                        Text(capability.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if pluginManager.registryUpdate(for: plugin.id) != nil {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            }

            Text(plugin.source == .builtIn ? String(localized: "Built-in") : String(localized: "User"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail Pane

    private var selectedPlugin: PluginEntry? {
        guard let id = selectedPluginId else { return nil }
        return pluginManager.plugins.first { $0.id == id }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected = selectedPlugin {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(selected.name)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { selected.isEnabled },
                            set: { pluginManager.setEnabled($0, pluginId: selected.id) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel(String(format: String(localized: "Enable %@"), selected.name))
                    }

                    Text("v\(selected.version) · \(selected.source == .builtIn ? String(localized: "Built-in") : String(localized: "User-installed"))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let registryPlugin = pluginManager.registryUpdate(for: selected.id) {
                        updateActionView(for: selected, registryPlugin: registryPlugin)
                    }

                    if !selected.pluginDescription.isEmpty {
                        Text(selected.pluginDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("Bundle ID")
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            Text(selected.id)
                                .textSelection(.enabled)
                                .gridColumnAlignment(.leading)
                        }

                        if !selected.capabilities.isEmpty {
                            GridRow {
                                Text("Capabilities")
                                    .foregroundStyle(.secondary)
                                Text(selected.capabilities.map(\.displayName).joined(separator: ", "))
                            }
                        }

                        if let typeId = selected.databaseTypeId {
                            GridRow {
                                Text("Database Type")
                                    .foregroundStyle(.secondary)
                                Text(typeId)
                            }

                            if !selected.additionalTypeIds.isEmpty {
                                GridRow {
                                    Text("Also handles")
                                        .foregroundStyle(.secondary)
                                    Text(selected.additionalTypeIds.joined(separator: ", "))
                                }
                            }

                            if let port = selected.defaultPort {
                                GridRow {
                                    Text("Default Port")
                                        .foregroundStyle(.secondary)
                                    Text("\(port)")
                                }
                            }
                        }
                    }
                    .font(.callout)

                    if let settable = pluginManager.pluginInstances[selected.id] as? any SettablePluginDiscoverable,
                       let pluginSettings = settable.settingsView() {
                        Divider()
                        pluginSettings
                    }

                    if selected.source == .userInstalled {
                        Divider()
                        Button("Uninstall", role: .destructive) {
                            uninstallPlugin(selected)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a Plugin")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Update

    @ViewBuilder
    private func updateActionView(for plugin: PluginEntry, registryPlugin: RegistryPlugin) -> some View {
        if let progress = installTracker.state(for: plugin.id) {
            switch progress.phase {
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .completed:
                Label(
                    String(format: String(localized: "Updated to v%@"), registryPlugin.version),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(Color(nsColor: .systemGreen))
                .font(.callout)
            case .failed:
                Button(String(localized: "Retry Update")) { updatePlugin(registryPlugin) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                Text(String(format: String(localized: "v%@ available"), registryPlugin.version))
                    .font(.callout)
                    .foregroundStyle(.blue)
                Button(String(localized: "Update")) { updatePlugin(registryPlugin) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func updatePlugin(_ registryPlugin: RegistryPlugin) {
        Task {
            installTracker.beginInstall(pluginId: registryPlugin.id)
            do {
                _ = try await pluginManager.updateFromRegistry(registryPlugin) { fraction in
                    installTracker.updateProgress(pluginId: registryPlugin.id, fraction: fraction)
                    if fraction >= 1.0 {
                        installTracker.markInstalling(pluginId: registryPlugin.id)
                    }
                }
                installTracker.completeInstall(pluginId: registryPlugin.id)
            } catch {
                installTracker.failInstall(pluginId: registryPlugin.id, error: error.localizedDescription)
                errorAlertTitle = String(localized: "Plugin Update Failed")
                errorAlertMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    // MARK: - Actions

    private func installFromFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Plugin")
        panel.allowedContentTypes = [.zip] + (UTType("com.tablepro.plugin").map { [$0] } ?? [])
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false

        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.installPlugin(from: url)
        }
    }

    private func installPlugin(from url: URL) {
        Task {
            do {
                let entry = try await pluginManager.installPlugin(from: url)
                selectedPluginId = entry.id
            } catch {
                errorAlertTitle = String(localized: "Plugin Installation Failed")
                errorAlertMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func uninstallPlugin(_ plugin: PluginEntry) {
        Task {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Uninstall Plugin?"),
                message: String(format: String(localized: "\"%@\" will be removed from your system. This action cannot be undone."), plugin.name),
                confirmButton: String(localized: "Uninstall"),
                cancelButton: String(localized: "Cancel")
            )

            guard confirmed else { return }

            do {
                try pluginManager.uninstallPlugin(id: plugin.id)
                selectedPluginId = nil
            } catch {
                errorAlertTitle = String(localized: "Uninstall Failed")
                errorAlertMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }
}

// MARK: - PluginCapability Display Names

private extension PluginCapability {
    var displayName: String {
        switch self {
        case .databaseDriver: String(localized: "Database Driver")
        case .exportFormat: String(localized: "Export Format")
        case .importFormat: String(localized: "Import Format")
        }
    }
}

#Preview {
    InstalledPluginsView()
        .frame(width: 650, height: 500)
}
