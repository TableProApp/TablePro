//
//  PluginInstallStatusRow.swift
//  TablePro
//

import SwiftUI

struct PluginInstallStatusRow: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        LabeledContent(String(localized: "Plugin")) {
            if coordinator.isInstallingPlugin {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Installing..."))
                        .foregroundStyle(.secondary)
                }
            } else if let error = coordinator.pluginInstallError {
                HStack(spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
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
}
