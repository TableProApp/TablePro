//
//  RegistryPluginDetailView.swift
//  TablePro
//

import SwiftUI

struct RegistryPluginDetailView: View {
    let plugin: RegistryPlugin
    let isInstalled: Bool
    var hasUpdate: Bool = false
    let installProgress: InstallProgress?
    let downloadCount: Int?
    let onInstall: () -> Void
    var onUpdate: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(plugin.name)
                    .font(.title3.weight(.semibold))

                Text(plugin.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Category")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(plugin.category.displayName)
                            .gridColumnAlignment(.leading)
                    }

                    GridRow {
                        Text("Author")
                            .foregroundStyle(.secondary)
                        Text(plugin.author.name)
                    }

                    GridRow {
                        Text("Version")
                            .foregroundStyle(.secondary)
                        Text(plugin.version)
                    }

                    if let minVersion = plugin.minAppVersion {
                        GridRow {
                            Text("Requires")
                                .foregroundStyle(.secondary)
                            Text("v\(minVersion)+")
                        }
                    }

                    if let count = downloadCount {
                        GridRow {
                            Text("Downloads")
                                .foregroundStyle(.secondary)
                            Text(formattedCount(count))
                        }
                    }

                    if let homepage = plugin.homepage, let url = URL(string: homepage),
                       let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                        GridRow {
                            Text("Homepage")
                                .foregroundStyle(.secondary)
                            Link(homepage, destination: url)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    if plugin.isVerified {
                        GridRow {
                            Text("Status")
                                .foregroundStyle(.secondary)
                            Label("Verified", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .font(.callout)

                if !isInstalled {
                    Divider()
                    installActionView
                } else if hasUpdate {
                    Divider()
                    updateActionView
                } else {
                    Divider()
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .font(.callout)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var installActionView: some View {
        if let progress = installProgress {
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
                    Text("Installing...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .completed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .font(.callout)
            case .failed:
                Button("Retry Install") { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        } else {
            Button(plugin.category == .theme
                ? String(localized: "Install Theme")
                : String(localized: "Install Plugin")) { onInstall() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(installProgress != nil)
        }
    }

    @ViewBuilder
    private var updateActionView: some View {
        if let progress = installProgress {
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
                Label("Updated", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .font(.callout)
            case .failed:
                Button(String(localized: "Retry Update")) { onUpdate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        } else {
            Button(String(format: String(localized: "Update to v%@"), plugin.version)) { onUpdate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
    }

    private func formattedCount(_ count: Int) -> String {
        let formatted = count.formatted(.number.grouping(.automatic))
        return count == 1
            ? String(format: String(localized: "%@ download"), formatted)
            : String(format: String(localized: "%@ downloads"), formatted)
    }
}
