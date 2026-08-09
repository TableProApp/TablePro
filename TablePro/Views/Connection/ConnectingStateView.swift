//
//  ConnectingStateView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ConnectingStateView: View {
    let connection: DatabaseConnection
    let onCancel: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(String(format: String(localized: "Connecting to %@"), connection.name))
            } icon: {
                ConnectionTypeIcon(type: connection.type, pulses: true)
            }
        } description: {
            VStack(spacing: 14) {
                ConnectionEndpointLabel(connection: connection)
                ProgressView()
                    .controlSize(.small)
            }
        } actions: {
            Button(role: .cancel, action: onCancel) {
                Text(String(localized: "Cancel"))
                    .frame(minWidth: 80)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
