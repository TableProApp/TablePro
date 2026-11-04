//
//  ConnectionField+PasswordHiding.swift
//  TablePro
//

import TableProPluginKit

extension Sequence where Element == ConnectionField {
    func hidesPassword(forValues values: [String: String]) -> Bool {
        hidesBuiltInField(forValues: values, when: \.hidesPassword)
    }

    func hidesUsername(forValues values: [String: String]) -> Bool {
        hidesBuiltInField(forValues: values, when: \.hidesUsername)
    }

    private func hidesBuiltInField(
        forValues values: [String: String],
        when flag: (ConnectionField) -> Bool
    ) -> Bool {
        contains { field in
            guard field.section == .authentication, flag(field) else { return false }
            switch field.fieldType {
            case .toggle:
                return values[field.id] == "true"
            case .dropdown:
                let value = values[field.id] ?? field.defaultValue
                return value != field.defaultValue
            default:
                return isVisible(field, forValues: values)
            }
        }
    }

    /// A field whose controlling field is hidden is hidden too, whatever value that controller
    /// still holds. DuckDB's Certificate Fingerprint follows SSL Mode, which only Remote shows, so
    /// without this a Local row left on Verify Fingerprint would require a field nobody can see.
    func isVisible(_ field: ConnectionField, forValues values: [String: String]) -> Bool {
        isVisible(field, forValues: values, visited: [])
    }

    // A plugin can declare a cycle, so a controller already on the path decides nothing; neither
    // does one the list lacks, since the form never shows it to hide.
    private func isVisible(
        _ field: ConnectionField,
        forValues values: [String: String],
        visited: Set<String>
    ) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        let controller = first { $0.id == rule.fieldId }
        let currentValue = values[rule.fieldId] ?? controller?.defaultValue ?? ""
        guard rule.values.contains(currentValue) else { return false }
        let path = visited.union([field.id])
        guard let controller, !path.contains(controller.id) else { return true }
        return isVisible(controller, forValues: values, visited: path)
    }
}

extension PluginManager {
    func hidesPassword(for connection: DatabaseConnection) -> Bool {
        if PluginMetadataRegistry.shared.snapshot(for: connection.type)?
            .connection.hidesBuiltInPassword == true {
            return true
        }
        return additionalConnectionFields(for: connection.type)
            .hidesPassword(forValues: connection.additionalFields)
    }
}
