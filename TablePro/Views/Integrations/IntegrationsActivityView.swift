//
//  IntegrationsActivityView.swift
//  TablePro
//

import SwiftUI

enum IntegrationsActivitySection: String, Hashable, CaseIterable, Identifiable {
    case activityLog
    case connectedClients

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activityLog:
            String(localized: "Activity Log")
        case .connectedClients:
            String(localized: "Connected Clients")
        }
    }

    var systemImage: String {
        switch self {
        case .activityLog:
            "list.bullet.rectangle"
        case .connectedClients:
            "person.2.circle"
        }
    }
}

struct IntegrationsActivitySidebar: View {
    @ObservedObject var selection: SidebarSelection<IntegrationsActivitySection>

    var body: some View {
        List(selection: $selection.value) {
            Section(String(localized: "Activity")) {
                Label(IntegrationsActivitySection.activityLog.title,
                      systemImage: IntegrationsActivitySection.activityLog.systemImage)
                    .tag(IntegrationsActivitySection.activityLog)
            }
            Section(String(localized: "Status")) {
                Label(IntegrationsActivitySection.connectedClients.title,
                      systemImage: IntegrationsActivitySection.connectedClients.systemImage)
                    .tag(IntegrationsActivitySection.connectedClients)
            }
        }
        .listStyle(.sidebar)
    }
}

struct IntegrationsActivityDetail: View {
    @ObservedObject var selection: SidebarSelection<IntegrationsActivitySection>

    var body: some View {
        switch selection.value {
        case .activityLog:
            IntegrationsActivityLogPane()
        case .connectedClients:
            IntegrationsConnectedClientsPane()
        case .none:
            UnavailableStateView(
                String(localized: "No Selection"),
                systemImage: "sidebar.left",
                description: Text(String(localized: "Choose a section from the sidebar."))
            )
        }
    }
}
