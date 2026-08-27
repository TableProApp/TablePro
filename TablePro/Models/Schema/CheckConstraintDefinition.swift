//
//  CheckConstraintDefinition.swift
//  TablePro
//
//  Represents a check constraint definition for schema editing.
//

import Foundation
import TableProPluginKit

/// Check constraint definition for schema modification (editable structure tab)
struct EditableCheckConstraintDefinition: Hashable, Codable, Identifiable {
    var id: UUID
    var name: String
    var expression: String
    var columns: [String]
    var isValidated: Bool

    /// Create a placeholder constraint for adding new constraints
    static func placeholder() -> EditableCheckConstraintDefinition {
        EditableCheckConstraintDefinition(
            id: UUID(),
            name: "",
            expression: "",
            columns: [],
            isValidated: true
        )
    }

    /// Check if this definition is valid (not a placeholder)
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !expression.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Create from existing CheckConstraintInfo
    static func from(_ info: CheckConstraintInfo) -> EditableCheckConstraintDefinition {
        EditableCheckConstraintDefinition(
            id: info.id,
            name: info.name,
            expression: info.expression,
            columns: info.columns,
            isValidated: info.isValidated
        )
    }

    func toPlugin() -> PluginCheckConstraintDefinition {
        PluginCheckConstraintDefinition(name: name, expression: expression)
    }

    /// Convert back to CheckConstraintInfo
    func toCheckConstraintInfo() -> CheckConstraintInfo {
        CheckConstraintInfo(
            name: name,
            expression: expression,
            columns: columns,
            isValidated: isValidated
        )
    }

    func withNewIdentity() -> EditableCheckConstraintDefinition {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
