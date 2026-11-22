import SwiftUI

internal struct MCPSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var mcp: SettingsSlice<MCPSettings>
    @EnvironmentObject private var model: MCPSettingsModel

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._mcp = ObservedObject(wrappedValue: context.settings.mcpSlice)
    }

    internal var body: some View {
        MCPSettingsView(settings: $mcp.value, model: model) {
            context.navigation.open(.root(.ai), recordsHistory: true)
        }
    }
}

internal struct MCPSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext
    @EnvironmentObject private var model: MCPSettingsModel

    internal var body: some View {
        switch route {
        case .page(.mcpApprovals):
            MCPApprovalsPage(context: context, model: model)
        case .page(.mcpTokens):
            MCPTokenListView(model: model) {
                context.settings.mcpSlice.value.port
            }
        default:
            EmptyView()
        }
    }
}

// The approval mode lives in the MCP slice, so only this page observes it.
private struct MCPApprovalsPage: View {
    @ObservedObject private var mcp: SettingsSlice<MCPSettings>
    @ObservedObject var model: MCPSettingsModel

    init(context: SettingsPaneContext, model: MCPSettingsModel) {
        self._mcp = ObservedObject(wrappedValue: context.settings.mcpSlice)
        self.model = model
    }

    var body: some View {
        MCPGrantListView(model: model, approval: mcp.value.connectionApproval)
    }
}

// The model sits on the stack, so the root and both pages share one load and keep it across pushes.
internal struct MCPStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext
    @StateObject private var model = MCPSettingsModel()

    internal init(context: SettingsPaneContext) {
        self.context = context
    }

    internal func body(content: Content) -> some View {
        content
            .environmentObject(model)
            .modifier(MCPVisitRefresh(visit: context.visit, model: model))
    }
}

private struct MCPVisitRefresh: ViewModifier {
    @ObservedObject var visit: SettingsPaneVisit
    let model: MCPSettingsModel

    func body(content: Content) -> some View {
        content
            .task(id: visit.count) {
                model.activate()
                await model.refresh()
            }
    }
}
