import SwiftUI
import TableProPluginKit

struct PluginDetailPage: View {
    let entry: PluginEntry
    let isStaged: Bool
    let context: SettingsPaneContext
    @EnvironmentObject private var model: ExtensionsPaneModel
    @State private var loaded: PluginLoadedInstance?

    var body: some View {
        Form {
            Section {
                PluginHeaderCard(iconName: entry.pluginIconName, name: entry.name, detail: headerDetail)
            }

            PluginStatusSection(
                trackerId: entry.id,
                displayName: entry.name,
                isStaged: isStaged,
                route: .plugin(id: entry.id),
                context: context,
                tracker: model.manager.installTracker
            )

            Section(String(localized: "Details")) {
                LabeledContent(String(localized: "Version"), value: entry.version)
                LabeledContent(
                    String(localized: "Source"),
                    value: entry.source == .builtIn ? String(localized: "Built-in") : String(localized: "User-installed")
                )
                if !entry.capabilities.isEmpty {
                    LabeledContent(String(localized: "Capabilities"), value: capabilityNames)
                }
                if let typeId = entry.databaseTypeId {
                    LabeledContent(String(localized: "Database type"), value: typeId)
                    if !entry.additionalTypeIds.isEmpty {
                        LabeledContent(String(localized: "Also handles"), value: entry.additionalTypeIds.joined(separator: ", "))
                    }
                    if let port = entry.defaultPort {
                        LabeledContent(String(localized: "Default port"), value: String(port))
                    }
                }
                LabeledContent(String(localized: "Bundle ID")) {
                    Text(verbatim: entry.id)
                        .textSelection(.enabled)
                }
            }

            if let loaded, let settable = loaded.settable, let options = settable.settingsView() {
                Section(optionsTitle) {
                    options
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if entry.source == .userInstalled {
                Section {
                    LabeledContent {
                        Button(String(localized: "Uninstall…"), role: .destructive) {
                            model.uninstall(id: entry.id, name: entry.name, isDriver: entry.databaseTypeId != nil, context: context)
                        }
                        .accessibilityLabel(String(format: String(localized: "Uninstall %@"), entry.name))
                        .accessibilityIdentifier("extensions-plugin-uninstall")
                    } label: {
                        Text("Uninstall this plugin")
                        Text("The plugin moves to the Trash and its settings are deleted.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-page-plugin")
        .task(id: entry.id) {
            loaded = await PluginLoadedInstance.load(entry, manager: model.manager)
        }
    }

    private var capabilityNames: String {
        entry.capabilities.map(\.settingsDisplayName).joined(separator: ", ")
    }

    private var headerDetail: String {
        let description = loaded?.description ?? entry.pluginDescription
        return description.isEmpty ? capabilityNames : description
    }

    private var optionsTitle: String {
        if entry.exportFormatId != nil { return String(localized: "Export Options") }
        if entry.importFormatId != nil { return String(localized: "Import Options") }
        return String(localized: "Options")
    }
}

// A format's code loads off the main actor first, so opening its page never holds the window on a signature check.
struct PluginLoadedInstance {
    let description: String
    let settable: (any SettablePluginDiscoverable)?

    @MainActor
    static func load(_ entry: PluginEntry, manager: PluginManager) async -> PluginLoadedInstance? {
        if let formatId = entry.exportFormatId {
            await manager.loadLazyExportExecutable(formatId: formatId)
            _ = manager.exportPlugin(forFormat: formatId)
        } else if let formatId = entry.importFormatId {
            await manager.loadLazyImportExecutable(formatId: formatId)
            _ = manager.importPlugin(forFormat: formatId)
        }
        // A driver's code is never loaded just to show its page.
        guard let instance = manager.pluginInstances[entry.id] else { return nil }
        return PluginLoadedInstance(
            description: type(of: instance).pluginDescription,
            settable: instance as? any SettablePluginDiscoverable
        )
    }
}

struct PluginHeaderCard: View {
    let iconName: String
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            PluginIconView(name: iconName, size: 32)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.headline)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// Shown only while the tracker has this plugin or an update waits for a relaunch.
struct PluginStatusSection: View {
    let trackerId: String?
    let displayName: String
    let isStaged: Bool
    let route: SettingsRoute
    let context: SettingsPaneContext
    @ObservedObject var tracker: PluginInstallTracker
    @EnvironmentObject private var model: ExtensionsPaneModel

    var body: some View {
        let install = trackerId.flatMap { tracker.entries[$0] }
        if let status = ExtensionsPageStatus(phase: install?.phase, isStaged: isStaged) {
            Section {
                switch status {
                case .running(let phase):
                    LabeledContent {
                        Button(String(localized: "Cancel")) {
                            if let trackerId { tracker.cancel(pluginId: trackerId) }
                        }
                        .disabled(phase == .installing)
                        .accessibilityLabel(String(format: String(localized: "Cancel installing %@"), displayName))
                    } label: {
                        Text(verbatim: ExtensionsPluginStatus(phase: phase, isStaged: false, isBuiltIn: false, version: "").text)
                        ExtensionsInstallProgress(phase: phase)
                            .accessibilityLabel(Text(verbatim: String(format: String(localized: "Installing %@…"), displayName)))
                    }
                case .failed(let reason):
                    LabeledContent {
                        HStack(spacing: 8) {
                            if let install, install.retry != nil {
                                Button(String(localized: "Try Again")) {
                                    model.retryInstall(install, context: context, replacing: route)
                                }
                                .accessibilityLabel(String(format: String(localized: "Try installing %@ again"), displayName))
                            }
                            Button(String(localized: "Dismiss")) {
                                if let trackerId { tracker.cancel(pluginId: trackerId) }
                            }
                        }
                    } label: {
                        NoticeLabel(reason, severity: .error)
                    }
                case .staged:
                    LabeledContent {
                        Button(String(localized: "Relaunch")) {
                            UpdateCenter.shared.relaunch()
                        }
                    } label: {
                        Text("Updates when TablePro relaunches")
                    }
                }
            }
        }
    }
}

extension PluginCapability {
    var settingsDisplayName: String {
        switch self {
        case .databaseDriver: String(localized: "Database Driver")
        case .exportFormat: String(localized: "Export Format")
        case .importFormat: String(localized: "Import Format")
        case .documentInspector: String(localized: "Document Inspector")
        @unknown default: String(localized: "Unknown")
        }
    }
}
