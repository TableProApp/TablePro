//
//  ConnectionFormToolbar.swift
//  TablePro
//

import SwiftUI

struct ConnectionFormToolbar: ToolbarContent {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel")) {
                coordinator.cancel()
            }
            .keyboardShortcut(.cancelAction)
        }

        if coordinator.isNew {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) {
                    coordinator.save()
                }
                .disabled(!coordinator.isFormValid || coordinator.isInstallingPlugin)
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(coordinator.isNew
                   ? String(localized: "Save & Connect")
                   : String(localized: "Save")) {
                coordinator.saveAndConnect()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!coordinator.isFormValid || coordinator.isInstallingPlugin)
        }
    }
}
