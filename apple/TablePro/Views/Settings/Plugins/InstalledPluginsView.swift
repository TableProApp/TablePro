import AppKit
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct InstalledPluginsView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryClient: RegistryClient
    // isInstalling reads the tracker, which the plugin manager does not republish.
    @ObservedObject private var installTracker = PluginInstallTracker.shared
    @ObservedObject private var navigation = PluginsSettingsNavigation.shared
    @ObservedObject private var modules = AppModuleSettings.shared
    @ObservedObject private var updates = UpdateCenter.shared

    @State private var selection: PluginListSelection?
    @State private var searchText = ""
    @State private var showErrorAlert = false
    @State private var errorAlertTitle = ""
    @State private var errorAlertMessage = ""
    @State private var isRetryingRejected = false

    init(registryClient: RegistryClient = .shared) {
        self.registryClient = registryClient
    }

    private var filteredPlugins: [PluginEntry] {
        if searchText.isEmpty { return pluginManager.plugins }
        return pluginManager.plugins.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredModules: [AppModule] {
        AppModule.allCases.filter { $0.matches(filter: searchText) }
    }

    private var filteredRejected: [RejectedPlugin] {
        if searchText.isEmpty { return pluginManager.rejectedPlugins }
        return pluginManager.rejectedPlugins.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HSplitView {
            pluginList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)

            detailPane
                .frame(minWidth: 340)
        }
        .task {
            await registryClient.fetch(policy: .ifStale)
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
                Task { @MainActor in
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

    // MARK: - Relaunch Row

    // Untagged, so it never takes the selection; the list is where the pending removal is.
    private var relaunchRow: some View {
        HStack(spacing: 8) {
            Label {
                Text("Relaunch to finish removing plugins.")
                    .lineLimit(2)
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(String(localized: "Relaunch")) { updates.relaunch() }
                .controlSize(.small)
                .accessibilityIdentifier("plugins-relaunch-button")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Rejected Plugins

    private func rejectedRow(_ plugin: RejectedPlugin) -> some View {
        let status = RejectedPluginStatus(action: pluginManager.rejectedAction(for: plugin))
        return HStack(spacing: 8) {
            PluginIconView(name: PluginManager.iconName(forPrimaryTypeId: plugin.providedDatabaseTypeIds.first))
                .font(.title3)
                .frame(width: 24, height: 24)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .lineLimit(1)
                Text(status.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: status.severity.symbolName)
                .selectionAwareTint(status.severity.tint)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func rejectedDetail(_ plugin: RejectedPlugin) -> some View {
        let action = pluginManager.rejectedAction(for: plugin)
        let status = RejectedPluginStatus(action: action)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(plugin.name)
                    .font(.title3.weight(.semibold))

                NoticeLabel(plugin.reason, severity: status.severity)
                    .font(.callout)

                if let bundleId = plugin.bundleId {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("Bundle ID")
                                .foregroundStyle(.secondary)
                            Text(bundleId)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.callout)
                }

                Divider()

                HStack(spacing: 8) {
                    rejectedActionControl(for: plugin, action: action)
                    Button(String(localized: "Remove")) {
                        removeRejectedPlugin(plugin)
                    }
                    .accessibilityLabel(String(format: String(localized: "Remove %@"), plugin.name))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func rejectedActionControl(for plugin: RejectedPlugin, action: RejectedPluginAction) -> some View {
        switch action {
        case .updateAvailable(let registryPlugin):
            Button(String(localized: "Update Now")) {
                updatePlugin(registryPlugin)
            }
            .disabled(pluginManager.isInstalling)
            .accessibilityLabel(String(format: String(localized: "Update %@"), plugin.name))
        case .requiresAppUpdate:
            Button(updates.status.appUpdateTitle) {
                updates.performAppUpdateAction()
            }
            .disabled(!updates.isAppUpdateActionEnabled)
            .help(String(localized: "A newer TablePro is required to load this plugin."))
        case .awaitingCompatibleBuild:
            if pluginManager.isUpdatingEnabled {
                if isRetryingRejected {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(String(localized: "Try Again")) {
                        retryRejectedPlugins()
                    }
                }
            }
        case .notInRegistry:
            EmptyView()
        }
    }

    private func retryRejectedPlugins() {
        isRetryingRejected = true
        Task {
            defer { isRetryingRejected = false }
            await pluginManager.retryRejectedPluginRepairs(registryClient: registryClient)
        }
    }

    private func removeRejectedPlugin(_ plugin: RejectedPlugin) {
        let fm = FileManager.default
        if fm.fileExists(atPath: plugin.url.path) {
            do {
                try fm.removeItem(at: plugin.url)
            } catch CocoaError.fileNoSuchFile {
            } catch {
                errorAlertTitle = String(localized: "Remove Failed")
                errorAlertMessage = error.localizedDescription
                showErrorAlert = true
                return
            }
        }
        pluginManager.removeFromRejected(url: plugin.url)
        if selection == .rejected(plugin.url) { selection = nil }
    }

    // MARK: - Plugin List

    private var pluginList: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $searchText, placeholder: String(localized: "Filter…"))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            ScrollViewReader { proxy in
                List(selection: $selection) {
                    if pluginManager.needsRestart {
                        Section {
                            relaunchRow
                        }
                    }
                    if !filteredModules.isEmpty {
                        // Untagged, so a module row toggles but never takes the plugin selection.
                        Section(String(localized: "Modules")) {
                            ForEach(filteredModules, id: \.self) { module in
                                ModuleToggleRow(module: module, settings: modules)
                            }
                        }
                    }
                    if !filteredRejected.isEmpty {
                        Section(String(localized: "Couldn't Load")) {
                            ForEach(filteredRejected, id: \.url) { plugin in
                                rejectedRow(plugin)
                                    .tag(PluginListSelection.rejected(plugin.url))
                                    .id(PluginListSelection.rejected(plugin.url))
                            }
                        }
                    }
                    Section(String(localized: "Plugins")) {
                        ForEach(filteredPlugins) { plugin in
                            pluginRow(plugin)
                                .tag(PluginListSelection.plugin(plugin.id))
                                .id(PluginListSelection.plugin(plugin.id))
                        }
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    listBottomBar
                }
                .onAppear { revealRequestedPlugin() }
                .onChange(of: navigation.pendingRequest) { _ in
                    revealRequestedPlugin()
                }
                .onChange(of: selection) { selection in
                    guard let selection else { return }
                    proxy.scrollTo(selection)
                }
            }
        }
        .onChange(of: searchText) { _ in
            switch selection {
            case .plugin(let id) where !filteredPlugins.contains(where: { $0.id == id }):
                selection = nil
            case .rejected(let url) where !filteredRejected.contains(where: { $0.url == url }):
                selection = nil
            default:
                break
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
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("v\(plugin.version)")
                    if let capability = plugin.capabilities.first {
                        Text(capability.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if pluginManager.stagedPluginIds.contains(plugin.id) {
                    Text("Updates when TablePro relaunches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(plugin.source == .builtIn ? String(localized: "Built-in") : String(localized: "User"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail Pane

    private var selectedPlugin: PluginEntry? {
        guard case .plugin(let id) = selection else { return nil }
        return pluginManager.plugins.first { $0.id == id }
    }

    private var selectedRejected: RejectedPlugin? {
        guard case .rejected(let url) = selection else { return nil }
        return pluginManager.rejectedPlugins.first { $0.url == url }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let rejected = selectedRejected {
            rejectedDetail(rejected)
        } else if let selected = selectedPlugin {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selected.name)
                        .font(.title3.weight(.semibold))

                    Text("v\(selected.version), \(selected.source == .builtIn ? String(localized: "Built-in") : String(localized: "User-installed"))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

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
                                    Text(verbatim: "\(port)")
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
                    .font(.title)
                    .foregroundStyle(.tertiary)
                Text("Select a plugin to view details")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func updatePlugin(_ registryPlugin: RegistryPlugin) {
        Task {
            let result = await pluginManager.performRegistryUpdate(registryPlugin)
            if case .failed(let error) = result {
                errorAlertTitle = String(localized: "Plugin Update Failed")
                errorAlertMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    // MARK: - Actions

    private func revealRequestedPlugin() {
        guard let request = navigation.consumePendingRequest(),
              let target = PluginListSelection.revealTarget(
                  pluginId: request.pluginId,
                  loadedIds: pluginManager.plugins.map(\.id),
                  rejected: pluginManager.rejectedPlugins
              ) else { return }
        searchText = ""
        selection = target
    }

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
                selection = .plugin(entry.id)
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
                try await pluginManager.uninstallPlugin(id: plugin.id)
                selection = nil
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
        case .documentInspector: String(localized: "Document Inspector")
        @unknown default: String(localized: "Unknown")
        }
    }
}

#Preview {
    InstalledPluginsView()
        .frame(width: 650, height: 500)
}
