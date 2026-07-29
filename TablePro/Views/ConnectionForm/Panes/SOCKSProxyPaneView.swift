//
//  SOCKSProxyPaneView.swift
//  TablePro
//

import SwiftUI

struct SOCKSProxyPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable SOCKS Proxy"), isOn: $coordinator.socksProxy.state.enabled)
            } footer: {
                Text("Routes this connection through a SOCKS5 proxy. The database hostname is resolved by the proxy, so names that only resolve behind it still work.")
            }

            if coordinator.socksProxy.state.enabled {
                if !coordinator.otherEnabledTunnels(excluding: .socksProxy).isEmpty {
                    TunnelExclusivityBanner(coordinator: coordinator, currentKind: .socksProxy)
                }
                serverSection
                credentialsSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var serverSection: some View {
        Section(String(localized: "Proxy Server")) {
            TextField(
                String(localized: "Host"),
                text: $coordinator.socksProxy.state.host,
                prompt: Text(verbatim: "proxy.example.com")
            )
            .autocorrectionDisabled()
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
