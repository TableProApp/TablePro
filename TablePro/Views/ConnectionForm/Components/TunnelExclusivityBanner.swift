//
//  TunnelExclusivityBanner.swift
//  TablePro
//

import SwiftUI

struct TunnelExclusivityBanner: View {
    let coordinator: ConnectionFormCoordinator
    let currentKind: ConnectionTunnelKind

    var body: some View {
        Section {
            Label(
                String(
                    format: String(localized: "A connection can use one connection method at a time. Disable the other methods to use %@."),
                    currentKind.displayName
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            ForEach(coordinator.otherEnabledTunnels(excluding: currentKind)) { other in
                Button(String(format: String(localized: "Disable %@"), other.kind.displayName)) {
                    other.disable()
                }
            }
        }
    }
}
