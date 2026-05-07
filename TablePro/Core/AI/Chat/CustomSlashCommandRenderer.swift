//
//  CustomSlashCommandRenderer.swift
//  TablePro
//

import Foundation

/// Renders a `CustomSlashCommand` template into a final prompt by substituting
/// `{{query}}`, `{{schema}}`, `{{database}}`, and `{{body}}` placeholders with
/// the current chat context. Unknown placeholders pass through unchanged so
/// users can leave them visible if they want literal braces.
enum CustomSlashCommandRenderer {
    struct Context {
        let query: String?
        let schema: String?
        let database: String?
        let body: String
    }

    static func render(_ command: CustomSlashCommand, context: Context) -> String {
        var output = command.promptTemplate
        let substitutions: [(CustomSlashCommandVariable, String)] = [
            (.query, context.query ?? ""),
            (.schema, context.schema ?? ""),
            (.database, context.database ?? ""),
            (.body, context.body)
        ]
        for (variable, value) in substitutions {
            output = output.replacingOccurrences(of: variable.placeholder, with: value)
        }
        return output
    }
}
