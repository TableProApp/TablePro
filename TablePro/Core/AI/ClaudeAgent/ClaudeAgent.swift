//
//  ClaudeAgent.swift
//  TablePro
//

import Foundation

enum ClaudeAgent {
    static let mcpServerName = "tablepro"

    static let curatedModels: [CuratedModel] = [
        CuratedModel(id: "opus", displayName: "Claude Opus"),
        CuratedModel(id: "sonnet", displayName: "Claude Sonnet"),
        CuratedModel(id: "haiku", displayName: "Claude Haiku")
    ]

    static let systemPrompt = """
    You are a SQL assistant embedded in TablePro, a macOS database client. \
    Answer questions about the user's databases and help them write, explain, and fix SQL. \
    Keep responses focused and concise. When database tools are available, use them to \
    ground your answers in the user's actual schema rather than guessing.
    """
}
