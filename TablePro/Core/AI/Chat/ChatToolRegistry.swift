//
//  ChatToolRegistry.swift
//  TablePro
//

import Foundation
import os

/// Process-wide registry of `ChatTool` implementations available to AI chat.
@MainActor
final class ChatToolRegistry {
    static let shared = ChatToolRegistry()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatToolRegistry")

    private static let readOnlyToolNames: Set<String> = [
        "list_connections",
        "get_connection_status",
        "list_databases",
        "list_schemas",
        "list_tables",
        "describe_table",
        "get_table_ddl"
    ]

    private static let editModeToolNames: Set<String> = readOnlyToolNames.union([
        "execute_query"
    ])

    private var tools: [String: any ChatTool] = [:]

    init() {}

    func register(_ tool: any ChatTool) {
        let existing = tools[tool.name]
        tools[tool.name] = tool
        if existing != nil {
            Self.logger.warning("Replaced ChatTool '\(tool.name, privacy: .public)' in registry; second registration won")
        }
    }

    func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    func tool(named name: String) -> (any ChatTool)? {
        tools[name]
    }

    func tool(named name: String, in mode: AIChatMode) -> (any ChatTool)? {
        guard Self.isToolAllowed(name: name, in: mode) else { return nil }
        return tools[name]
    }

    var allTools: [any ChatTool] {
        tools.values
            .sorted { $0.name < $1.name }
    }

    var allSpecs: [ChatToolSpec] {
        allTools.map(\.spec)
    }

    func allTools(for mode: AIChatMode) -> [any ChatTool] {
        allTools.filter { Self.isToolAllowed(name: $0.name, in: mode) }
    }

    func allSpecs(for mode: AIChatMode) -> [ChatToolSpec] {
        allTools(for: mode).map(\.spec)
    }

    nonisolated static func isToolAllowed(name: String, in mode: AIChatMode) -> Bool {
        switch mode {
        case .ask:
            return readOnlyToolNames.contains(name)
        case .edit:
            return editModeToolNames.contains(name)
        case .agent:
            return true
        }
    }
}
