import SwiftUI

struct MCPSettingsView: View {
    @Binding var settings: MCPSettings

    var body: some View {
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
