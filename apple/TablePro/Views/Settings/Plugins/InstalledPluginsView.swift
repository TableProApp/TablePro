import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Extensions pane root. The toolbar filter narrows it; the pages are their own views in the pane's stack.
struct InstalledPluginsView: View {
    private static let importTypes: [UTType] = [.zip] + (UTType("com.tablepro.plugin").map { [$0] } ?? [])

    private let context: SettingsPaneContext
    @EnvironmentObject private var model: ExtensionsPaneModel
    @ObservedObject private var filter: SettingsPaneFilter
    @ObservedObject private var reveal: SettingsPluginReveal
    @ObservedObject private var visit: SettingsPaneVisit
    @State private var isDropTargeted = false
    @State private var isImporting = false

    init(context: SettingsPaneContext) {
        self.context = context
        _filter = ObservedObject(wrappedValue: context.filter ?? SettingsPaneFilter())
        _reveal = ObservedObject(wrappedValue: context.navigation.pluginReveal)
        _visit = ObservedObject(wrappedValue: context.visit)
    }

    var body: some View {
        let content = model.snapshot.filtered(filter.query)
        Group {
            if content.isFiltering && content.isEmpty {
                UnavailableStateView.search(text: filter.query)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("extensions-no-results")
            } else {
                form(content)
            }
        }
        .task(id: visit.count) {
            _ = await model.registryClient.fetch(policy: .ifStale)
        }
        .task(id: reveal.pending?.id) {
            await model.revealPending(in: context)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.install(urls, context: context)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay { dropHighlight }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            model.install(urls, context: context)
        }
    }

    private func form(_ content: ExtensionsFilteredContent) -> some View {
        Form {
            ExtensionsAttentionSection(snapshot: model.snapshot, context: context, tracker: model.manager.installTracker)

            if !content.rejected.isEmpty {
                Section(String(localized: "Couldn't Load")) {
                    ForEach(content.rejected) { row in
                        ExtensionsRejectedRowView(row: row, context: context, tracker: model.manager.installTracker)
                    }
                }
            }

            if !content.modules.isEmpty {
                Section(String(localized: "Modules")) {
                    ForEach(content.modules, id: \.self) { module in
                        ModuleToggleRow(module: module)
                    }
                }
            }

            ForEach(content.groups) { section in
                Section(section.group.title) {
                    ForEach(section.rows) { row in
                        ExtensionsPluginRowView(row: row, context: context, tracker: model.manager.installTracker)
                    }
                }
            }

            // System Settings puts Add below its list.
            if !content.isFiltering {
                Section {
                    LabeledContent {
                        Button(String(localized: "Install from File…")) {
                            isImporting = true
                        }
                        .accessibilityIdentifier("extensions-install-from-file")
                    } label: {
                        Text("Install a plugin")
                        Text("Choose a .tableplugin bundle or a .zip archive, or drop one on this window.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 2)
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// Unfiltered: a relaunch or an install in progress matters whatever the query.
private struct ExtensionsAttentionSection: View {
    let snapshot: ExtensionsSnapshot
    let context: SettingsPaneContext
    @ObservedObject var tracker: PluginInstallTracker
    @EnvironmentObject private var model: ExtensionsPaneModel

    var body: some View {
        let activities = ExtensionsSnapshot.activities(in: tracker.entries, excluding: snapshot.trackedIds)
        if snapshot.relaunch != nil || !activities.isEmpty {
            Section {
                if let relaunch = snapshot.relaunch {
                    LabeledContent {
                        Button(String(localized: "Relaunch")) {
                            UpdateCenter.shared.relaunch()
                        }
                        .accessibilityIdentifier("plugins-relaunch-button")
                    } label: {
                        Text("Relaunch TablePro to finish")
                        Text(verbatim: relaunch.text)
                    }
                }
                ForEach(activities) { entry in
                    activityRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ entry: PluginInstallTracker.Entry) -> some View {
        switch entry.phase {
        case .downloading, .installing:
            let title = String(format: String(localized: "Installing %@…"), entry.displayName)
            LabeledContent {
                Button(String(localized: "Cancel")) {
                    tracker.cancel(pluginId: entry.pluginId)
                }
                .disabled(entry.phase == .installing)
                .accessibilityLabel(String(format: String(localized: "Cancel installing %@"), entry.displayName))
            } label: {
                Text(verbatim: title)
                ExtensionsInstallProgress(phase: entry.phase)
                    .accessibilityLabel(Text(verbatim: title))
            }
        case .failed(let reason):
            LabeledContent {
                HStack(spacing: 8) {
                    if entry.retry != nil {
                        Button(String(localized: "Try Again")) {
                            model.retryInstall(entry, context: context)
                        }
                        .accessibilityLabel(String(format: String(localized: "Try installing %@ again"), entry.displayName))
                    }
                    Button(String(localized: "Dismiss")) {
                        tracker.cancel(pluginId: entry.pluginId)
                    }
                }
            } label: {
                Text(verbatim: String(format: String(localized: "%@ could not be installed"), entry.displayName))
                Text(verbatim: reason)
            }
        case .completed:
            EmptyView()
        }
    }
}

private struct ExtensionsRejectedRowView: View {
    let row: ExtensionsRejectedRow
    let context: SettingsPaneContext
    @ObservedObject var tracker: PluginInstallTracker
    @EnvironmentObject private var model: ExtensionsPaneModel

    var body: some View {
        NavigationLink(value: SettingsRoute.rejectedPlugin(row.url)) {
            HStack(spacing: 10) {
                PluginIconView(name: row.iconName, size: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.name)
                        .lineLimit(1)
                    Text(verbatim: caption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: row.severity.symbolName)
                    .selectionAwareTint(row.severity.tint)
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            if row.canRemove {
                Button(String(localized: "Move to Trash…")) {
                    model.moveToTrash(row.url, context: context)
                }
            }
            Button(String(localized: "Show in Finder")) {
                model.showInFinder(row.url)
            }
        }
        .modifier(ExtensionsOptionalAction(name: row.canRemove ? String(localized: "Move to Trash") : nil) {
            model.moveToTrash(row.url, context: context)
        })
        .accessibilityAction(named: Text("Show in Finder")) {
            model.showInFinder(row.url)
        }
        .accessibilityIdentifier("extensions-rejected-row-\(row.url.lastPathComponent)")
    }

    private var caption: String {
        switch row.trackerId.flatMap({ tracker.entries[$0]?.phase }) {
        case .downloading?: String(localized: "Downloading update…")
        case .installing?: String(localized: "Installing update…")
        default: row.caption
        }
    }
}

private struct ExtensionsPluginRowView: View {
    let row: ExtensionsPluginRow
    let context: SettingsPaneContext
    @ObservedObject var tracker: PluginInstallTracker
    @EnvironmentObject private var model: ExtensionsPaneModel

    var body: some View {
        let install = tracker.entries[row.id]
        NavigationLink(value: SettingsRoute.plugin(id: row.id)) {
            HStack(spacing: 10) {
                PluginIconView(name: row.iconName, size: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.name)
                        .lineLimit(1)
                    ExtensionsPluginStatusLine(
                        status: ExtensionsPluginStatus(
                            phase: install?.phase,
                            isStaged: row.isStaged,
                            isBuiltIn: row.isBuiltIn,
                            version: row.version
                        )
                    )
                }
            }
        }
        .contextMenu { menu(install) }
        .modifier(ExtensionsOptionalAction(name: row.isBuiltIn ? nil : String(localized: "Uninstall")) {
            model.uninstall(row, context: context)
        })
        .modifier(ExtensionsOptionalAction(name: row.isBuiltIn ? nil : String(localized: "Show in Finder")) {
            model.showInFinder(row.url)
        })
        .accessibilityIdentifier("extensions-plugin-row-\(row.id)")
    }

    @ViewBuilder
    private func menu(_ install: PluginInstallTracker.Entry?) -> some View {
        if let install {
            switch install.phase {
            case .downloading, .installing:
                Button(String(localized: "Cancel Update")) {
                    tracker.cancel(pluginId: row.id)
                }
                .disabled(install.phase == .installing)
            case .failed:
                if install.retry != nil {
                    Button(String(localized: "Try Again")) {
                        model.retryInstall(install, context: context)
                    }
                }
                Button(String(localized: "Dismiss")) {
                    tracker.cancel(pluginId: row.id)
                }
            case .completed:
                EmptyView()
            }
        }
        if !row.isBuiltIn {
            if install.map({ $0.phase != .completed }) == true {
                Divider()
            }
            Button(String(localized: "Uninstall…")) {
                model.uninstall(row, context: context)
            }
            Button(String(localized: "Show in Finder")) {
                model.showInFinder(row.url)
            }
        }
    }
}

struct ExtensionsPluginStatusLine: View {
    let status: ExtensionsPluginStatus

    var body: some View {
        Group {
            if status == .failed {
                NoticeLabel(status.text, severity: .warning)
            } else {
                Text(verbatim: status.text)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
    }
}

struct ExtensionsInstallProgress: View {
    let phase: PluginInstallTracker.Phase

    var body: some View {
        if case .downloading(let fraction?) = phase {
            ProgressView(value: fraction)
                .controlSize(.small)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
    }
}

// VoiceOver gets every row action the context menu offers.
struct ExtensionsOptionalAction: ViewModifier {
    let name: String?
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let name {
            content.accessibilityAction(named: Text(verbatim: name), action)
        } else {
            content
        }
    }
}
