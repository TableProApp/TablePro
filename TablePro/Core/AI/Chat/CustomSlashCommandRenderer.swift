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
        let values: [String: String] = [
            CustomSlashCommandVariable.query.rawValue: context.query ?? "",
            CustomSlashCommandVariable.schema.rawValue: context.schema ?? "",
            CustomSlashCommandVariable.database.rawValue: context.database ?? "",
            CustomSlashCommandVariable.body.rawValue: context.body
        ]
        let template = command.promptTemplate
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if let openRange = template.range(of: "{{", range: index..<template.endIndex) {
                result.append(contentsOf: template[index..<openRange.lowerBound])
                if let closeRange = template.range(of: "}}", range: openRange.upperBound..<template.endIndex) {
                    let name = String(template[openRange.upperBound..<closeRange.lowerBound])
                    if let value = values[name] {
                        result.append(value)
                    } else {
                        result.append(contentsOf: template[openRange.lowerBound..<closeRange.upperBound])
                    }
                    index = closeRange.upperBound
                } else {
                    result.append(contentsOf: template[openRange.lowerBound..<template.endIndex])
                    break
                }
            } else {
                result.append(contentsOf: template[index..<template.endIndex])
                break
            }
        }
        return result
    }
}
