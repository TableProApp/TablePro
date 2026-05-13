//
//  AdvancedPaneView.swift
//  TablePro
//

import SwiftUI

struct AdvancedPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        ConnectionAdvancedView(
            additionalFieldValues: $coordinator.advanced.additionalFieldValues,
            startupCommands: $coordinator.advanced.startupCommands,
            preConnectScript: $coordinator.advanced.preConnectScript,
            aiPolicy: $coordinator.advanced.aiPolicy,
            externalAccess: $coordinator.advanced.externalAccess,
            localOnly: $coordinator.advanced.localOnly,
            databaseType: coordinator.network.type,
            additionalConnectionFields: coordinator.advanced.advancedFields
        )
    }
}
