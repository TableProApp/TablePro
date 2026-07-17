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

    func isVisible(_ field: ConnectionField, forValues values: [String: String]) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        let defaultValue = first { $0.id == rule.fieldId }?.defaultValue ?? ""
        let currentValue = values[rule.fieldId] ?? defaultValue
        return rule.values.contains(currentValue)
    }
}

extension PluginManager {
    func hidesPassword(for connection: DatabaseConnection) -> Bool {
        if PluginMetadataRegistry.shared.snapshot(forTypeId: connection.type.pluginTypeId)?
            .connection.hidesBuiltInPassword == true {
            return true
        }
        return additionalConnectionFields(for: connection.type)
            .hidesPassword(forValues: connection.additionalFields)
    }
}
