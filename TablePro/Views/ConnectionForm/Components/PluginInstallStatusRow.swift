//
//  PluginInstallStatusRow.swift
//  TablePro
//

import SwiftUI

struct PluginInstallStatusRow: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    private var tracker: PluginInstallTracker { PluginInstallTracker.shared }

    var body: some View {
        LabeledContent(String(localized: "Plugin")) {
            if coordinator.isInstallingPlugin {
                installProgress
            } else if let error = coordinator.pluginInstallError {
                HStack(spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .lineLimit(2)
                    Button(String(localized: "Retry")) {
                        coordinator.pluginInstallError = nil
                        coordinator.installPlugin(for: coordinator.network.type)
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Text(String(localized: "Not Installed"))
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Install")) {
                        coordinator.installPlugin(for: coordinator.network.type)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// An indeterminate spinner says nothing about a download that can take a while. The tracker
    /// already publishes a fraction, so the bar shows it, and staging is called out explicitly so
    /// a full bar never reads as ready.
    @ViewBuilder
    private var installProgress: some View {
        switch tracker.state(forDatabaseType: coordinator.network.type)?.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .frame(width: 160)
                .accessibilityLabel(Text("Downloading plugin"))
        case .installing:
            labelledSpinner(String(localized: "Installing…"))
        case .stagedPendingActivation:
            Text("Ready after restart")
                .foregroundStyle(.secondary)
        case .completed:
            Text("Installed")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .none:
            labelledSpinner(String(localized: "Installing…"))
        }
    }

    private func labelledSpinner(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }
}
