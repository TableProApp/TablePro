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

    /// The built-in tools, in one list so a test can hold the same set the app registers rather
    /// than a hand copy that drifts from it.
    static func makeTools() -> [any ChatTool] {
        [
            ListConnectionsChatTool(),
            GetConnectionStatusChatTool(),
            ListDatabasesChatTool(),
            ListSchemasChatTool(),
            ListTablesChatTool(),
            DescribeTableChatTool(),
            GetTableDDLChatTool(),
            ExecuteQueryChatTool(),
            ConfirmDestructiveOperationChatTool()
        ]
    }

    static func register() {
        let registry = ChatToolRegistry.shared
        for tool in makeTools() {
            registry.registerBuiltIn(tool)
        }
    }
}
