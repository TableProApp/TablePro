//
//  ConnectionFormSidebar.swift
//  TablePro
//

import SwiftUI

struct ConnectionFormSidebar: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        List(selection: $coordinator.selectedPane) {
            ForEach(coordinator.visiblePanes) { pane in
                row(for: pane)
                    .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    @ViewBuilder
    private func row(for pane: ConnectionFormPane) -> some View {
        let badgeIcon = pane.validationBadge(for: coordinator)
        Label {
            HStack(spacing: 6) {
                Text(pane.title)
                Spacer(minLength: 4)
                if let badgeIcon {
                    Image(systemName: badgeIcon)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .font(.caption)
                }
            }
        } icon: {
            Image(systemName: pane.systemImage)
        }
    }
}
