//
//  CustomSlashCommand.swift
//  TablePro
//

import Foundation

/// A user-defined slash command for the AI chat. Users author these in
/// Settings -> AI -> Custom Commands. Templates support variables that get
/// substituted at execution time: `{{query}}` (current editor query),
/// `{{schema}}` (the formatted schema for the active connection),
/// `{{database}}` (active database name), `{{body}}` (text typed after the
/// command in the composer).
struct CustomSlashCommand: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var promptTemplate: String

    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        promptTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.promptTemplate = promptTemplate
    }

    /// Whether the command has the minimum fields populated to run.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !promptTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum CustomSlashCommandVariable: String, CaseIterable {
    case query
    case schema
    case database
    case body

    var placeholder: String { "{{\(rawValue)}}" }
}
