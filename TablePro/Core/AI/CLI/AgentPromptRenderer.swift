//
//  AgentPromptRenderer.swift
//  TablePro
//

import Foundation

enum AgentPromptRenderer {
    static func renderPrompt(turns: [ChatTurnWire], includingSystemPrompt systemPrompt: String?) -> String {
        var sections: [String] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            sections.append(systemPrompt)
        }
        for turn in turns {
            let text = turnText(turn)
            guard !text.isEmpty else { continue }
            switch turn.role {
            case .user:
                sections.append("User: \(text)")
            case .assistant:
                sections.append("Assistant: \(text)")
            case .system:
                sections.append(text)
            }
        }
        return sections.joined(separator: "\n\n")
    }

    static func turnText(_ turn: ChatTurnWire) -> String {
        var parts: [String] = []
        for block in turn.blocks {
            switch block.kind {
            case .text(let text):
                if !text.isEmpty { parts.append(text) }
            case .sqlWalkthrough(let walkthrough):
                let text = walkthrough.transcriptText
                if !text.isEmpty { parts.append(text) }
            case .toolResult(let result):
                if !result.content.isEmpty { parts.append("Result: \(result.content)") }
            case .toolUse, .attachment, .reasoning, .image:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }
}
