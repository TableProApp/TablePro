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

    var allTools: [any ChatTool] {
        tools.values
            .sorted { $0.name < $1.name }
    }

    var allSpecs: [ChatToolSpec] {
        allTools.map(\.spec)
    }
}
