//
//  CloudflareTunnelPaneView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct CloudflareTunnelPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    private var viewModel: CloudflareTunnelPaneViewModel { coordinator.cloudflareTunnel }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable Cloudflare Tunnel"), isOn: $coordinator.cloudflareTunnel.state.enabled)
            } footer: {
                Text("Starts and stops `cloudflared access tcp` with this connection and routes it through a local port.")
            }

            if coordinator.cloudflareTunnel.state.enabled {
                if !coordinator.otherEnabledTunnels(excluding: .cloudflare).isEmpty {
                    TunnelExclusivityBanner(coordinator: coordinator, currentKind: .cloudflare)
                }
                hostnameSection
                authenticationSection
                listenerSection
                binarySection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sections

    private var hostnameSection: some View {
        Section(String(localized: "Access Application")) {
            TextField(
                String(localized: "Hostname"),
                text: $coordinator.cloudflareTunnel.state.accessHostname,
                prompt: Text(verbatim: "db.example.com")
            )
            .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var authenticationSection: some View {
        Section(String(localized: "Authentication")) {
            Picker(String(localized: "Method"), selection: $coordinator.cloudflareTunnel.state.authMethod) {
                ForEach(CloudflareAuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }

            switch coordinator.cloudflareTunnel.state.authMethod {
            case .browserSSO:
                Button("Sign In with Browser...") {
                    viewModel.signInWithBrowser()
                }
                .disabled(coordinator.cloudflareTunnel.state.accessHostname.trimmingCharacters(in: .whitespaces).isEmpty)
                if let signInError = viewModel.signInError {
                    Label(signInError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Signs in to Cloudflare Access once and caches the token, so connecting doesn't open a browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .serviceToken:
                SecureField(String(localized: "Client ID"), text: $coordinator.cloudflareTunnel.state.serviceTokenId)
                SecureField(String(localized: "Client Secret"), text: $coordinator.cloudflareTunnel.state.serviceTokenSecret)
                Text("The Access application policy must use a Service Auth rule, or Cloudflare still prompts for browser sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var listenerSection: some View {
        Section {
            Toggle(String(localized: "Choose port automatically"), isOn: $coordinator.cloudflareTunnel.state.automaticPort)
            if !coordinator.cloudflareTunnel.state.automaticPort {
                TextField(
                    String(localized: "Local port"),
                    text: $coordinator.cloudflareTunnel.state.localPort,
                    prompt: Text(verbatim: "5432")
                )
            }
            Toggle(String(localized: "Expose to local network"), isOn: $coordinator.cloudflareTunnel.state.exposeToLAN)
        } header: {
            Text("Local Listener")
        } footer: {
            if coordinator.cloudflareTunnel.state.exposeToLAN {
                Text("Listens on all interfaces (0.0.0.0), reachable from your local network.")
            } else {
                Text("Listens only on 127.0.0.1.")
            }
        }
    }

    @ViewBuilder
    private var binarySection: some View {
        Section {
            TextField(
                String(localized: "Path"),
                text: $coordinator.cloudflareTunnel.state.binaryPath,
                prompt: Text("Automatic")
            )
            Button("Choose...") {
                chooseBinary()
            }
            .controlSize(.small)

            if coordinator.cloudflareTunnel.state.binaryPath.isEmpty {
                if let resolved = viewModel.resolvedBinaryPath {
                    LabeledContent(String(localized: "Detected"), value: resolved)
                        .foregroundStyle(.secondary)
                } else if viewModel.didResolveBinary {
                    Label(
                        String(localized: "cloudflared not found. Install it with `brew install cloudflared`, or choose the binary above."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                }
            }
        } header: {
            Text(verbatim: "cloudflared")
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
            coordinator.cloudflareTunnel.state.binaryPath = url.path
        }
    }
}
