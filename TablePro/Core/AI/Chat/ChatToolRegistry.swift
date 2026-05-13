//
//  ChatToolRegistry.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class ChatToolRegistry {
    static let shared = ChatToolRegistry()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatToolRegistry")

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
        guard let tool = tools[name] else { return nil }
        guard tool.mode.isAllowed(in: mode) else { return nil }
        return tool
    }

    var allTools: [any ChatTool] {
        tools.values
            .sorted { $0.name < $1.name }
    }

    var allSpecs: [ChatToolSpec] {
        allTools.map(\.spec)
    }

    func allTools(for mode: AIChatMode) -> [any ChatTool] {
        allTools.filter { $0.mode.isAllowed(in: mode) }
    }

    func allSpecs(for mode: AIChatMode) -> [ChatToolSpec] {
        allTools(for: mode).map(\.spec)
    }

    func requiresApproval(toolName: String) -> Bool {
        guard let tool = tools[toolName] else { return true }
        return tool.mode.requiresApproval
    }

    func isToolAllowed(name: String, in mode: AIChatMode) -> Bool {
        guard let tool = tools[name] else {
            return mode == .agent
        }
        return tool.mode.isAllowed(in: mode)
    }
}
