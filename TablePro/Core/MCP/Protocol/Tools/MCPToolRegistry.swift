import Foundation

public enum MCPToolRegistry {
    public static let allTools: [any MCPToolImplementation] = registered
        .sorted { type(of: $0).name < type(of: $1).name }

    private static let registered: [any MCPToolImplementation] = [
        BrowseTableTool(),
        ConfirmDestructiveOperationTool(),
        ConnectTool(),
        CountRowsTool(),
        CreateDatabaseTool(),
        DescribeCreateDatabaseOptionsTool(),
        DescribeTableTool(),
        DisconnectTool(),
        DropDatabaseObjectTool(),
        ExecuteQueryTool(),
        ExplainQueryTool(),
        ExportDataTool(),
        FocusQueryTabTool(),
        GetConnectionStatusTool(),
        GetDatabaseStatisticsTool(),
        GetTableDdlTool(),
        GetTableStatisticsTool(),
        GetViewDefinitionTool(),
        InsertRowsTool(),
        ListConnectionsTool(),
        ListDatabasesTool(),
        ListFavoriteTablesTool(),
        ListForeignKeysTool(),
        ListGrantsTool(),
        ListIndexesTool(),
        ListMaintenanceOperationsTool(),
        ListPartitionsTool(),
        ListPrincipalsTool(),
        ListRecentTablesTool(),
        ListRecentTabsTool(),
        ListRoutinesTool(),
        ListSchemasTool(),
        ListSessionContextsTool(),
        ListTablesTool(),
        ListTriggersTool(),
        ListUserDefinedTypesTool(),
        OpenConnectionWindowTool(),
        OpenTableTabTool(),
        QuoteIdentifiersTool(),
        RunMaintenanceTool(),
        SearchQueryHistoryTool(),
        SearchSchemaTool(),
        ServerDashboardTool(),
        StopServerSessionTool(),
        SwitchDatabaseTool(),
        SwitchSchemaTool(),
        TransactionControlTool()
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

    public static func tools(for scopes: Set<MCPScope>) -> [any MCPToolImplementation] {
        allTools.filter { type(of: $0).requiredScopes.isSubset(of: scopes) }
    }

    public static func descriptors(for scopes: Set<MCPScope>) -> [JsonValue] {
        tools(for: scopes).map(descriptor(for:))
    }

    public static func descriptor(for tool: any MCPToolImplementation) -> JsonValue {
        let toolType = type(of: tool)
        var fields: [String: JsonValue] = [
            "name": .string(toolType.name),
            "description": .string(toolType.description),
            "inputSchema": toolType.inputSchema
        ]
        if let title = toolType.title {
            fields["title"] = .string(title)
        }
        if let outputSchema = toolType.outputSchema {
            fields["outputSchema"] = outputSchema
        }
        if !toolType.icons.isEmpty {
            fields["icons"] = .array(toolType.icons.map { $0.asJsonValue })
        }
        if let annotations = toolType.annotations.asJsonValue {
            fields["annotations"] = annotations
        }
        return .object(fields)
    }
}
