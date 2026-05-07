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
            inputSchema: Self.normalizeForCopilot(inputSchema)
        )
    }

    private static func normalizeForCopilot(_ schema: JSONValue) -> JSONValue {
        guard case .object(var dict) = schema else { return schema }
        if dict["required"] == nil {
            dict["required"] = .array([])
        }
        return .object(dict)
    }
}
