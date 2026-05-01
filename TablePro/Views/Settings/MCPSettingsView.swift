import SwiftUI

struct MCPSettingsView: View {
    @Binding var settings: MCPSettings

    @State private var selectedPane: IntegrationsPane = .settings

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedPane) {
                ForEach(IntegrationsPane.allCases) { pane in
                    Text(pane.label).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            switch selectedPane {
            case .settings:
                Form {
                    MCPSection(settings: $settings)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            case .activityLog:
                MCPAuditLogView()
            }
        }
    }
}

private enum IntegrationsPane: String, CaseIterable, Identifiable {
    case settings
    case activityLog

    var id: String { rawValue }

    var label: String {
        switch self {
        case .settings:
            return String(localized: "Settings")
        case .activityLog:
            return String(localized: "Activity Log")
        }
    }
}

#Preview {
    MCPSettingsView(settings: .constant(.default))
        .frame(width: 520, height: 540)
}
