import SwiftUI

struct PluginInstallStatusRow: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    @ObservedObject private var tracker = PluginInstallTracker.shared

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

    // A zero fraction means not started; see PluginInstallProgressPresenter.update(fraction:).
    @ViewBuilder
    private var installProgress: some View {
        switch tracker.state(forDatabaseType: coordinator.network.type)?.phase {
        case .downloading(let fraction) where fraction > 0:
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .frame(width: 160)
                .accessibilityLabel(Text("Downloading plugin"))
        case .downloading:
            labelledSpinner(String(localized: "Downloading…"))
        case .installing:
            labelledSpinner(String(localized: "Installing…"))
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
