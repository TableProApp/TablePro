import SwiftUI

struct MCPSettingsView: View {
    @Binding var settings: MCPSettings

    var body: some View {
        TabView {
            settingsTab
                .tabItem {
                    Label(String(localized: "Settings"), systemImage: "gearshape")
                }

            MCPAuditLogView()
                .tabItem {
                    Label(String(localized: "Activity Log"), systemImage: "list.bullet.rectangle")
                }
        }
    }

    private var settingsTab: some View {
        Form {
            MCPSection(settings: $settings)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    MCPSettingsView(settings: .constant(.default))
        .frame(width: 520, height: 540)
}
