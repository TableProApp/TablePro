//
//  TestConnectionStatusButton.swift
//  TablePro
//

import SwiftUI

struct TestConnectionStatusButton: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Button {
            coordinator.test()
        } label: {
            HStack(spacing: 6) {
                statusIcon
                Text(coordinator.testSucceeded
                     ? String(localized: "Connected")
                     : String(localized: "Test Connection"))
            }
        }
        .disabled(coordinator.isTesting
                  || coordinator.isInstallingPlugin
                  || !coordinator.isFormValid)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        if coordinator.isTesting {
            return String(localized: "Testing connection")
        }
        if coordinator.testSucceeded {
            return String(localized: "Connection succeeded")
        }
        return String(localized: "Test the current connection settings")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if coordinator.isTesting {
            ProgressView()
                .controlSize(.small)
        } else if coordinator.testSucceeded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        }
    }
}
