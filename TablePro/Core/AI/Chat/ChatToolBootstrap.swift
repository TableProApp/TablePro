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

    static func register() {
        let registry = ChatToolRegistry.shared
        registry.register(ListConnectionsChatTool())
        registry.register(GetConnectionStatusChatTool())
        registry.register(ListDatabasesChatTool())
        registry.register(ListSchemasChatTool())
        registry.register(ListTablesChatTool())
        registry.register(DescribeTableChatTool())
        registry.register(GetTableDDLChatTool())
    }
}
