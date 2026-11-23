import AppKit
import SwiftUI

struct RejectedPluginDetailPage: View {
    let row: ExtensionsRejectedRow
    let context: SettingsPaneContext
    @ObservedObject var tracker: PluginInstallTracker
    @ObservedObject private var updates = UpdateCenter.shared
    @EnvironmentObject private var model: ExtensionsPaneModel

    var body: some View {
        Form {
            Section {
                PluginHeaderCard(iconName: row.iconName, name: row.name, detail: caption)
            }

            Section {
                LabeledContent {
                    actionControl
                } label: {
                    NoticeLabel(row.reason, severity: row.severity)
                }
                if model.retryFailures.contains(row.url) {
                    NoticeLabel(
                        String(localized: "TablePro couldn't reach the plugin registry to update this plugin. Check your connection and try again."),
                        severity: .warning
                    )
                }
            }

            PluginStatusSection(
                trackerId: row.trackerId,
                displayName: row.name,
                isStaged: false,
                route: .rejectedPlugin(row.url),
                context: context,
                tracker: tracker
            )

            Section(String(localized: "Details")) {
                if let bundleId = row.bundleId {
                    LabeledContent(String(localized: "Bundle ID")) {
                        Text(verbatim: bundleId)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent {
                    Button {
                        model.showInFinder(row.url)
                    } label: {
                        Image(systemName: "arrow.forward")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Show in Finder"))
                    .accessibilityLabel(String(localized: "Show in Finder"))
                } label: {
                    Text("Location")
                    Text(verbatim: location)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(location)
                }
            }

            if row.canRemove {
                Section {
                    LabeledContent {
                        Button(String(localized: "Move to Trash…")) {
                            model.moveToTrash(row.url, context: context)
                        }
                        .accessibilityLabel(String(format: String(localized: "Move %@ to the Trash"), row.name))
                    } label: {
                        Text("Remove this plugin")
                        Text("You can put it back from the Trash.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-page-rejected-plugin")
    }

    private var location: String {
        (row.url.path as NSString).abbreviatingWithTildeInPath
    }

    private var isOwnInstallRunning: Bool {
        row.trackerId.flatMap { tracker.entries[$0]?.phase.isRunning } ?? false
    }

    private var caption: String {
        switch row.trackerId.flatMap({ tracker.entries[$0]?.phase }) {
        case .downloading?: String(localized: "Downloading update…")
        case .installing?: String(localized: "Installing update…")
        default: row.caption
        }
    }

    @ViewBuilder private var actionControl: some View {
        switch row.action {
        case .update(let registryId):
            Button(String(localized: "Update Now")) {
                guard let registryPlugin = model.registryPlugin(id: registryId) else { return }
                model.update(registryPlugin, context: context, replacing: .rejectedPlugin(row.url))
            }
            .disabled(isOwnInstallRunning)
            .accessibilityLabel(String(format: String(localized: "Update %@"), row.name))
        case .appUpdate:
            Button(updates.status.appUpdateTitle) {
                updates.performAppUpdateAction()
            }
            .disabled(!updates.isAppUpdateActionEnabled)
            .help(String(localized: "A newer TablePro is required to load this plugin."))
        case .retry:
            if model.retrying.contains(row.url) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Checking for a compatible build"))
            } else {
                Button(String(localized: "Try Again")) {
                    model.retryRejected(row.url)
                }
            }
        case .noAction:
            EmptyView()
        }
    }
}
