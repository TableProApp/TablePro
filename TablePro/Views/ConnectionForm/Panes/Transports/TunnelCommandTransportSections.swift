//
//  TunnelCommandTransportSections.swift
//  TablePro
//

import SwiftUI

struct TunnelCommandTransportSections: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    private var viewModel: TunnelCommandPaneViewModel { coordinator.tunnelCommand }

    var body: some View {
        methodSection
        methodFieldsSection
        previewSection
    }

    // MARK: - Sections

    private var methodSection: some View {
        Section {
            Picker(String(localized: "Method"), selection: $coordinator.tunnelCommand.state.config.method) {
                ForEach(TunnelCommandMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
        } footer: {
            Text(methodFooter)
        }
    }

    @ViewBuilder
    private var methodFieldsSection: some View {
        switch coordinator.tunnelCommand.state.config.method {
        case .kubectl:
            kubectlSection
            executableSection(prompt: "/opt/homebrew/bin/kubectl")
        case .awsSSM:
            awsSection
            executableSection(prompt: "/usr/local/bin/aws")
        case .custom:
            customSection
        }
    }

    private var kubectlSection: some View {
        Section {
            TextField(
                String(localized: "Resource"),
                text: $coordinator.tunnelCommand.state.config.kubernetesResource,
                prompt: Text(verbatim: "service/postgres")
            )
            .autocorrectionDisabled()
            TextField(
                String(localized: "Namespace"),
                text: $coordinator.tunnelCommand.state.config.kubernetesNamespace,
                prompt: Text(verbatim: "production")
            )
            .autocorrectionDisabled()
            TextField(
                String(localized: "Context"),
                text: $coordinator.tunnelCommand.state.config.kubernetesContext,
                prompt: Text(verbatim: "optional")
            )
            .autocorrectionDisabled()
        } header: {
            Text("Kubernetes")
        } footer: {
            Text("The port comes from this connection's own port, forwarded from the resource you name here.")
        }
    }

    private var awsSection: some View {
        Section {
            TextField(
                String(localized: "Target"),
                text: $coordinator.tunnelCommand.state.config.awsTarget,
                prompt: Text(verbatim: "i-0123456789abcdef0")
            )
            .autocorrectionDisabled()
            TextField(
                String(localized: "Profile"),
                text: $coordinator.tunnelCommand.state.config.awsProfile,
                prompt: Text(verbatim: "optional")
            )
            .autocorrectionDisabled()
            TextField(
                String(localized: "Region"),
                text: $coordinator.tunnelCommand.state.config.awsRegion,
                prompt: Text(verbatim: "optional")
            )
            .autocorrectionDisabled()
        } header: {
            Text("AWS Systems Manager")
        } footer: {
            Text("The session forwards to this connection's host and port from the target instance, so the target is the bastion rather than the database.")
        }
    }

    private var customSection: some View {
        Section {
            TextField(
                String(localized: "Command"),
                text: $coordinator.tunnelCommand.state.config.command,
                prompt: Text(verbatim: "ssh -N -L {port}:{host}:{remotePort} bastion"),
                axis: .vertical
            )
            .lineLimit(2...5)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
        } header: {
            Text("Command")
        } footer: {
            Text(customCommandFooter)
        }
    }

    private func executableSection(prompt: String) -> some View {
        Section {
            TextField(
                String(localized: "Executable path"),
                text: $coordinator.tunnelCommand.state.config.executablePath,
                prompt: Text(verbatim: prompt)
            )
            .autocorrectionDisabled()
        } footer: {
            Text(
                """
                Leave blank to find it on your PATH. Apps launched from the Dock do not inherit \
                your shell's PATH, so a tool installed somewhere unusual needs its full path here.
                """
            )
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let preview = viewModel.previewCommand(
            remoteHost: coordinator.network.host,
            remotePort: Int(coordinator.network.port) ?? 0
        ) {
            Section {
                Text(verbatim: preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Will Run")
            }
        }
    }

    private var customCommandFooter: String {
        String(
            format: String(localized: """
                %1$@ is the local port, %2$@ and %3$@ are this connection's host and port. \
                The command runs directly rather than through a shell, so start it with \
                /usr/bin/env if you need environment variables.
                """),
            TunnelCommandLine.localPortPlaceholder,
            TunnelCommandLine.hostPlaceholder,
            TunnelCommandLine.remotePortPlaceholder
        )
    }

    private var methodFooter: String {
        switch coordinator.tunnelCommand.state.config.method {
        case .kubectl:
            return String(localized: "Forwards a port from a Kubernetes resource with kubectl port-forward.")
        case .awsSSM:
            return String(localized: "Opens an AWS Systems Manager port forwarding session through a target instance.")
        case .custom:
            return String(localized: "Runs a command you write. It must open the local port itself.")
        }
    }
}
