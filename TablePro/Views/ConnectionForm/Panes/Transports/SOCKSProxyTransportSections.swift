//
//  SOCKSProxyTransportSections.swift
//  TablePro
//

import SwiftUI

struct SOCKSProxyTransportSections: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        serverSection
        credentialsSection
    }

    private var serverSection: some View {
        Section(String(localized: "Proxy Server")) {
            TextField(
                String(localized: "Host"),
                text: $coordinator.socksProxy.state.host,
                prompt: Text(verbatim: "proxy.example.com")
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("connection-form-socks-host")
            TextField(
                String(localized: "Port"),
                text: $coordinator.socksProxy.state.port,
                prompt: Text(verbatim: "1080")
            )
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField(String(localized: "Username"), text: $coordinator.socksProxy.state.username)
                .autocorrectionDisabled()
            SecureField(String(localized: "Password"), text: $coordinator.socksProxy.state.password)
        } header: {
            Text("Credentials")
        } footer: {
            Text("Leave blank to connect without authentication. The password is stored in the macOS Keychain.")
        }
    }
}
