//
//  AIPromptTemplates+Rewrite.swift
//  TablePro
//

import Foundation

extension AIPromptTemplates {
    static func rewriteSelectionSystemPrompt(language: String, schemaContext: String? = nil) -> String {
        var prompt = """
            You rewrite \(language) on demand. The user has selected a snippet and given an instruction. \
            Return ONLY the replacement text. Rules: \
            - Output raw \(language) only. No prose, no markdown fences, no explanation. \
            - The output replaces the selected snippet verbatim. Preserve indentation that matches the surrounding code. \
            - If the instruction asks to leave behavior unchanged but reformat or rename, do that. \
            - If the instruction is unclear, return the snippet unchanged. \
            - Match the dialect of the surrounding query. \
            - Do not wrap the result in quotes or backticks.
            """
        if let schemaContext, !schemaContext.isEmpty {
            prompt += "\n\n" + schemaContext
        }
        return prompt
    }

    static func rewriteSelection(instruction: String, selection: String, fullQuery: String) -> String {
        let cappedFull = capQueryContext(fullQuery)
        return """
            Instruction:
            \(instruction)

            Selected \(selection.isEmpty ? "(empty)" : "snippet"):
            \(selection)

            Surrounding query:
            \(cappedFull)
            """
    }

    private static func capQueryContext(_ text: String) -> String {
        let nsText = text as NSString
        let cap = 4_000
        if nsText.length <= cap { return text }
        return nsText.substring(from: nsText.length - cap)
    }
}
