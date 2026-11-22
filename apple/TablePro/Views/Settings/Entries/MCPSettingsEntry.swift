import SwiftUI

internal struct MCPSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var mcp: SettingsSlice<MCPSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._mcp = ObservedObject(wrappedValue: context.settings.mcpSlice)
    }

    internal var body: some View {
        MCPSettingsView(settings: $mcp.value)
    }
}

internal struct MCPSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.mcpApprovals):
            Form { Section { MCPGrantListView() } }
                .formStyle(.grouped)
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct MCPStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
