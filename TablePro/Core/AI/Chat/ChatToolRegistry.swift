//
//  ChatToolRegistry.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class ChatToolRegistry {
    static let shared = ChatToolRegistry()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ChatToolRegistry")

    private var tools: [String: any ChatTool] = [:]
    private var builtInNames: Set<String> = []

    /// Injected so a test can exercise the allowlist without writing the real one.
    private let serverStore: MCPServerStore

    init(serverStore: MCPServerStore = .shared) {
        self.serverStore = serverStore
    }

    /// Claims a name for a tool the app ships. A later `register` cannot take that name.
    func registerBuiltIn(_ tool: any ChatTool) {
        tools[tool.name] = tool
        builtInNames.insert(tool.name)
    }

    /// Registers a tool that did not ship with the app, refusing any name a built-in already holds.
    ///
    /// This used to overwrite the built-in and log a warning, so anything that could reach the
    /// registry could replace `execute_query` with its own implementation and keep the name the
    /// approval rules are written against.
    @discardableResult
    func register(_ tool: any ChatTool) -> Bool {
        guard !builtInNames.contains(tool.name) else {
            Self.logger.error("Refused ChatTool '\(tool.name, privacy: .public)': the name belongs to a built-in")
            return false
        }
        if tools[tool.name] != nil {
            Self.logger.warning("Replaced ChatTool '\(tool.name, privacy: .public)' in registry; second registration won")
        }
        tools[tool.name] = tool
        return true
    }

    func unregister(name: String) {
        guard !builtInNames.contains(name) else {
            Self.logger.error("Refused to unregister built-in ChatTool '\(name, privacy: .public)'")
            return
        }
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

    // MARK: - Scoped resolution

    /// Built-in tools are offered to every session on every connection, so the mode is the whole
    /// filter for them. A tool from an outside MCP server is different: it is offered only to a
    /// session whose connection appears in that server's allowlist, which is a question a chat mode
    /// cannot express and the reason `ChatToolScope` carries the connection at all.
    ///
    /// The allowlist is consulted on resolution as well as on listing. Filtering only the list would
    /// leave a model that had seen the tool once, in an earlier turn or on another connection, able
    /// to call it by name.

    func tools(in scope: ChatToolScope) -> [any ChatTool] {
        allTools(for: scope.mode).filter { isReachable($0, in: scope) }
    }

    func specs(in scope: ChatToolScope) -> [ChatToolSpec] {
        tools(in: scope).map(\.spec)
    }

    func tool(named name: String, in scope: ChatToolScope) -> (any ChatTool)? {
        guard let tool = tool(named: name, in: scope.mode) else { return nil }
        return isReachable(tool, in: scope) ? tool : nil
    }

    func isToolAllowed(name: String, in scope: ChatToolScope) -> Bool {
        guard let tool = tools[name] else {
            return scope.mode == .agent
        }
        guard isReachable(tool, in: scope) else { return false }
        return tool.mode.isAllowed(in: scope.mode)
    }

    /// A built-in is reachable from every session. A remote tool is reachable only from a connection
    /// its server allows.
    private func isReachable(_ tool: any ChatTool, in scope: ChatToolScope) -> Bool {
        guard let remote = tool as? MCPRemoteToolAdapter else { return true }
        guard let server = serverStore.server(id: remote.serverId) else { return false }
        return server.allows(connectionId: scope.connectionId)
    }

    /// Whether a name belongs to a tool from an outside server. Read by the approval path, which
    /// forces every one of them to wait for a human whatever its declared mode says.
    func isRemoteTool(named name: String) -> Bool {
        tools[name] is MCPRemoteToolAdapter
    }
}
