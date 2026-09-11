//
//  ChatToolBootstrap.swift
//  TablePro
//

import Foundation

/// Registers the built-in chat tools at app launch and exposes the shared
/// `MCPConnectionBridge` instance the tools delegate to. Call `register()` once
/// from `AppDelegate.applicationDidFinishLaunching(_:)`.
@MainActor
enum ChatToolBootstrap {
    static let bridge = MCPConnectionBridge()
    static let authPolicy = MCPAuthPolicy()

    static func register() {
        let registry = ChatToolRegistry.shared
        registry.registerBuiltIn(ListConnectionsChatTool())
        registry.registerBuiltIn(GetConnectionStatusChatTool())
        registry.registerBuiltIn(ListDatabasesChatTool())
        registry.registerBuiltIn(ListSchemasChatTool())
        registry.registerBuiltIn(ListTablesChatTool())
        registry.registerBuiltIn(DescribeTableChatTool())
        registry.registerBuiltIn(GetTableDDLChatTool())
        registry.registerBuiltIn(ExecuteQueryChatTool())
        registry.registerBuiltIn(ExplainQueryChatTool())
        registry.registerBuiltIn(ConfirmDestructiveOperationChatTool())
    }
}
