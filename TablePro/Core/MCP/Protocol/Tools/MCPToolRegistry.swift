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

    private static let toolsByName: [String: any MCPToolImplementation] = {
        var map: [String: any MCPToolImplementation] = [:]
        for tool in allTools {
            map[type(of: tool).name] = tool
        }
        return map
    }()

    public static func tool(named name: String) -> (any MCPToolImplementation)? {
        toolsByName[name]
    }
}
