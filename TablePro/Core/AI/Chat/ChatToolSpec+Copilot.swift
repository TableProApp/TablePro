//
//  ChatToolSpec+Copilot.swift
//  TablePro
//

import Foundation

extension ChatToolSpec {
    func asCopilotToolInformation() -> CopilotLanguageModelToolInformation {
        CopilotLanguageModelToolInformation(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
    }
}
