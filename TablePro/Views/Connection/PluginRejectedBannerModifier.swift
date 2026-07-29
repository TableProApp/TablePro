//
//  PluginRejectedBannerModifier.swift
//  TablePro
//

import SwiftUI

struct PluginRejectedBannerModifier: ViewModifier {
    let databaseType: DatabaseType
    private let pluginManager = PluginManager.shared
    private let registryClient = RegistryClient.shared
    private let installTracker = PluginInstallTracker.shared

    @State private var errorMessage: String?
    @State private var showError = false

    private var rejectedPlugin: RejectedPlugin? {
        let typeId = databaseType.pluginTypeId
        return pluginManager.rejectedPlugins.first { rejected in
            rejected.bundleId == typeId || rejected.registryId == typeId
        }
    }

    private var registryEntry: RegistryPlugin? {
        guard let rejected = rejectedPlugin else { return nil }
        return pluginManager.registryPlugin(for: rejected)
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let plugin = rejectedPlugin {
                banner(for: plugin)
                Divider()
            }
            content
        }
        .alert(String(localized: "Plugin Update Failed"), isPresented: $showError) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func banner(for plugin: RejectedPlugin) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.body)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Plugin not loaded"))
                    .font(.callout.weight(.semibold))
                Text(plugin.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let registryPlugin = registryEntry {
                progressOrButton(registryPlugin: registryPlugin)
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(format: String(localized: "Plugin not loaded: %@. %@"), plugin.name, plugin.reason)
        )
    }

    @ViewBuilder
    private func progressOrButton(registryPlugin: RegistryPlugin) -> some View {
        if let progress = installTracker.state(for: registryPlugin.id) {
            switch progress.phase {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 60)
                    .progressViewStyle(.linear)
            case .installing:
                ProgressView().controlSize(.small)
            case .stagedPendingActivation:
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                updateButton(registryPlugin: registryPlugin)
            }
        } else {
            updateButton(registryPlugin: registryPlugin)
        }
    }

    @ViewBuilder
    private func updateButton(registryPlugin: RegistryPlugin) -> some View {
        Button(String(localized: "Update Plugin")) {
            triggerUpdate(registryPlugin)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityLabel(String(format: String(localized: "Update %@ plugin"), registryPlugin.name))
    }

    private func triggerUpdate(_ registryPlugin: RegistryPlugin) {
        Task {
            let result = await pluginManager.performRegistryUpdate(registryPlugin)
            if case .failed(let error) = result {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

extension View {
    func pluginRejectedBanner(for databaseType: DatabaseType) -> some View {
        modifier(PluginRejectedBannerModifier(databaseType: databaseType))
    }
}
