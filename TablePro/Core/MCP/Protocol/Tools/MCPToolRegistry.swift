import Foundation

public enum MCPToolRegistry {
    public static let allTools: [any MCPToolImplementation] = [
        ListConnectionsTool(),
        GetConnectionStatusTool(),
        ListDatabasesTool(),
        ListSchemasTool(),
        ListTablesTool(),
        DescribeTableTool(),
        GetTableDdlTool(),
        ListRecentTabsTool(),
        SearchQueryHistoryTool(),
        FocusQueryTabTool(),
        ConnectTool(),
        DisconnectTool(),
        SwitchDatabaseTool(),
        SwitchSchemaTool(),
        ExecuteQueryTool(),
        ExportDataTool(),
        ConfirmDestructiveOperationTool(),
        OpenTableTabTool(),
        OpenConnectionWindowTool()
    ]

    public static func tool(named name: String) -> (any MCPToolImplementation)? {
        allTools.first { type(of: $0).name == name }
    }
}
