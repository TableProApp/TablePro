//
//  SSHPaneView.swift
//  TablePro
//

import SwiftUI

struct SSHPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        ConnectionSSHTunnelView(
            sshState: $coordinator.ssh.state,
            databaseType: coordinator.network.type
        )
    }
}
