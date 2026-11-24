//
//  ClaudeAgent.swift
//  TablePro
//

import Foundation

enum ClaudeAgent {
    static let mcpServerName = "tablepro"

    // The account's own default, which the claude CLI picks when no --model is given.
    static let defaultAlias = "default"

    // The claude CLI's aliases, which follow the newest model of each line (code.claude.com/docs/en/model-config).
    static let models: [AIModelInfo] = [
        AIModelInfo(id: defaultAlias, displayName: String(localized: "Default"), isProviderDefault: true),
        AIModelInfo(id: "opus", displayName: "Claude Opus"),
        AIModelInfo(id: "sonnet", displayName: "Claude Sonnet"),
        AIModelInfo(id: "haiku", displayName: "Claude Haiku")
    ]

    static let systemPrompt = """
    You are a SQL assistant embedded in TablePro, a macOS database client. \
    Answer questions about the user's databases and help them write, explain, and fix SQL. \
    Keep responses focused and concise. When database tools are available, use them to \
    ground your answers in the user's actual schema rather than guessing.
    """
}
