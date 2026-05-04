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
