//
//  CloudSQLProxyPaneView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct CloudSQLProxyPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    private var viewModel: CloudSQLProxyPaneViewModel { coordinator.cloudSQLProxy }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable Cloud SQL Auth Proxy"), isOn: $coordinator.cloudSQLProxy.state.enabled)
            } footer: {
                Text("Starts and stops the Cloud SQL Auth Proxy with this connection and routes it through a local port.")
            }

            if coordinator.cloudSQLProxy.state.enabled {
                if coordinator.ssh.state.enabled || coordinator.cloudflareTunnel.state.enabled {
                    mutualExclusivitySection
                }
                instanceSection
                authenticationSection
                networkSection
                listenerSection
                binarySection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sections

    @ViewBuilder
    private var mutualExclusivitySection: some View {
        Section {
            Label(
                String(localized: "A connection can use one connection method at a time. Disable the other one to use the Cloud SQL Auth Proxy."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            if coordinator.ssh.state.enabled {
                Button("Disable SSH Tunnel") {
                    coordinator.ssh.state.disable()
                }
            }
            if coordinator.cloudflareTunnel.state.enabled {
                Button("Disable Cloudflare Tunnel") {
                    coordinator.cloudflareTunnel.state.enabled = false
                }
            }
        }
    }

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
                        .stroke(Color.secondary.opacity(0.3))
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
                Button("Choose...") {
                    chooseBinary()
                }
                .controlSize(.small)
                if viewModel.isDownloading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Download cloud-sql-proxy...") {
                        viewModel.downloadBinary()
                    }
                    .controlSize(.small)
                }
            }

            if let error = viewModel.downloadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if coordinator.cloudSQLProxy.state.binaryPath.isEmpty {
                if let resolved = viewModel.resolvedBinaryPath {
                    LabeledContent(String(localized: "Detected"), value: resolved)
                        .foregroundStyle(.secondary)
                } else if viewModel.didResolveBinary {
                    Label(
                        String(localized: "cloud-sql-proxy not found. Install it with `brew install cloud-sql-proxy`, download it above, or choose the binary."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                }
            }
        } header: {
            Text(verbatim: "cloud-sql-proxy")
        }
    }

    // MARK: - Actions

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.cloudSQLProxy.state.binaryPath = url.path
        }
    }
}
