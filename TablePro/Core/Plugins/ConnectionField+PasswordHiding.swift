//
//  ConnectionField+PasswordHiding.swift
//  TablePro
//

import TableProPluginKit

extension Sequence where Element == ConnectionField {
    func hidesPassword(forValues values: [String: String]) -> Bool {
        contains { field in
            guard field.section == .authentication, field.hidesPassword else { return false }
            switch field.fieldType {
            case .toggle:
                return values[field.id] == "true"
            case .dropdown:
                let value = values[field.id] ?? field.defaultValue
                return value != field.defaultValue
            default:
                return true
            }
        }
    }
}

extension PluginManager {
    func hidesPassword(for connection: DatabaseConnection) -> Bool {
        additionalConnectionFields(for: connection.type)
            .hidesPassword(forValues: connection.additionalFields)
    }
}
