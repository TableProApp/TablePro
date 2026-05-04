//
//  SSLPaneView.swift
//  TablePro
//

import SwiftUI

struct SSLPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        ConnectionSSLView(
            sslMode: $coordinator.ssl.mode,
            sslCaCertPath: $coordinator.ssl.caCertPath,
            sslClientCertPath: $coordinator.ssl.clientCertPath,
            sslClientKeyPath: $coordinator.ssl.clientKeyPath
        )
    }
}
