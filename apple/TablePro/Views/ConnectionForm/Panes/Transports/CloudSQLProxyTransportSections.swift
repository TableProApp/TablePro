//
//  CloudSQLProxyTransportSections.swift
//  TablePro
//

import AppKit
import SwiftUI

struct CloudSQLProxyTransportSections: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    private var viewModel: CloudSQLProxyPaneViewModel { coordinator.cloudSQLProxy }

    var body: some View {
        instanceSection
        authenticationSection
        networkSection
        listenerSection
        binarySection
    }

    // MARK: - Sections

    private var instanceSection: some View {
        Section {
            TextField(
                String(localized: "Instance connection name"),
                text: $coordinator.cloudSQLProxy.state.instanceConnectionName,
                prompt: Text(verbatim: "project:region:instance")
            )
            .autocorrectionDisabled()
        } header: {
            Text("Cloud SQL Instance")
        } footer: {
            Text("Find this on the instance's overview page in the Google Cloud console.")
        }
    }

    @ViewBuilder
    private var authenticationSection: some View {
        Section {
            Picker(String(localized: "Credentials"), selection: $coordinator.cloudSQLProxy.state.authMode) {
                ForEach(CloudSQLProxyAuthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            switch coordinator.cloudSQLProxy.state.authMode {
            case .applicationDefault:
                Text("Uses this Mac's Application Default Credentials. Run `gcloud auth application-default login` first, or set GOOGLE_APPLICATION_CREDENTIALS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .serviceAccountKey:
                serviceAccountKeyEditor
            }

            Toggle(
                String(localized: "Use IAM database authentication"),
                isOn: $coordinator.cloudSQLProxy.state.useIAMAuth
            )
        } header: {
            Text("Authentication")
        } footer: {
            if coordinator.cloudSQLProxy.state.useIAMAuth {
                Text("Set the connection's username to the IAM principal (a user email, or `name@project.iam` for a service account). The database password is not used.")
            }
        }
    }

    private var serviceAccountKeyEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Service account key (JSON)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $coordinator.cloudSQLProxy.state.serviceAccountKeyJSON)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor))
                )
            Text("Stored in the macOS Keychain and written to a temporary file only while the proxy runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        Section {
            Toggle(String(localized: "Connect over private IP"), isOn: $coordinator.cloudSQLProxy.state.usePrivateIP)
        } footer: {
            Text("Use the instance's private IP address instead of its public IP.")
        }
    }

    @ViewBuilder
    private var listenerSection: some View {
        Section {
            Toggle(String(localized: "Choose port automatically"), isOn: $coordinator.cloudSQLProxy.state.automaticPort)
            if !coordinator.cloudSQLProxy.state.automaticPort {
                TextField(
                    String(localized: "Local port"),
                    text: $coordinator.cloudSQLProxy.state.localPort,
                    prompt: Text(verbatim: "5432")
                )
            }
        } header: {
            Text("Local Listener")
        } footer: {
            Text("Listens only on 127.0.0.1.")
        }
    }

    @ViewBuilder
    private var binarySection: some View {
        Section {
            TextField(
                String(localized: "Path"),
                text: $coordinator.cloudSQLProxy.state.binaryPath,
                prompt: Text("Automatic")
            )
            HStack {
                Button("Choose…") {
                    chooseBinary()
                }
                .controlSize(.small)
                if !viewModel.isDownloading {
                    Button("Download cloud-sql-proxy") {
                        viewModel.downloadBinary()
                    }
                    .controlSize(.small)
                }
            }

            switch viewModel.downloadPhase {
            case .downloading(let fraction):
                downloadProgress(fraction)
            case .failed(let message):
                warning(message)
            case .idle:
                EmptyView()
            }

            if coordinator.cloudSQLProxy.state.binaryPath.isEmpty, !viewModel.isDownloading {
                if let resolved = viewModel.resolvedBinaryPath {
                    LabeledContent(String(localized: "Detected"), value: resolved)
                        .foregroundStyle(.secondary)
                } else if viewModel.didResolveBinary {
                    warning(viewModel.binaryNotFoundMessage)
                }
            }
        } header: {
            Text(verbatim: "cloud-sql-proxy")
        }
    }

    private func downloadProgress(_ fraction: Double?) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: fraction) {
                Text("Downloading cloud-sql-proxy")
            } currentValueLabel: {
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            }
            .controlSize(.small)

            Button("Cancel") {
                viewModel.cancelDownload()
            }
            .controlSize(.small)
        }
    }

    private func warning(_ message: String) -> some View {
        Label {
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.presentAsSheet(for: NSApp.keyWindow) { url in
            guard let url else { return }
            coordinator.cloudSQLProxy.state.binaryPath = url.path
        }
    }
}
