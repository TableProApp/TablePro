//
//  ChatToolRegistry.swift
//  TablePro
//

import Foundation
import os

/// Process-wide registry of `ChatTool` implementations available to AI chat.
@MainActor
public final class ChatToolRegistry {
    public static let shared = ChatToolRegistry()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatToolRegistry")

    private var tools: [String: any ChatTool] = [:]

    public init() {}

    public func register(_ tool: any ChatTool) {
        let existing = tools[tool.name]
        tools[tool.name] = tool
        if existing != nil {
            Self.logger.warning("Replaced ChatTool '\(tool.name, privacy: .public)' in registry; second registration won")
        }
    }

    public func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    public func tool(named name: String) -> (any ChatTool)? {
        tools[name]
    }

    public var allTools: [any ChatTool] {
        tools.values
            .sorted { $0.name < $1.name }
    }

    public var allSpecs: [ChatToolSpec] {
        allTools.map(\.spec)
    }
}
