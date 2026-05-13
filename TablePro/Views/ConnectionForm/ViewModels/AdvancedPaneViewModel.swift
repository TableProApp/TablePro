//
//  AdvancedPaneViewModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@Observable
@MainActor
final class AdvancedPaneViewModel {
    var additionalFieldValues: [String: String] = [:]
    var startupCommands: String = ""
    var preConnectScript: String = ""
    var externalAccess: ExternalAccessLevel = .readOnly
    var localOnly: Bool = false
    var aiPolicy: AIConnectionPolicy?

    var coordinator: WeakCoordinatorRef?

    var advancedFields: [ConnectionField] {
        guard let type = coordinator?.value?.network.type else { return [] }
        return PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .advanced }
    }

    var validationIssues: [String] {
        var issues: [String] = []
        for field in advancedFields where field.isRequired && isFieldVisible(field) {
            let value = additionalFieldValues[field.id] ?? field.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(format: String(localized: "%@ is required"), field.label))
            }
        }
        return issues
    }

    func isFieldVisible(_ field: ConnectionField) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        let type = coordinator?.value?.network.type ?? .mysql
        let registry = PluginManager.shared.additionalConnectionFields(for: type)
        let defaultValue = registry.first { $0.id == rule.fieldId }?.defaultValue ?? ""
        let currentValue = additionalFieldValues[rule.fieldId] ?? defaultValue
        return rule.values.contains(currentValue)
    }

    func resetForType(_ newType: DatabaseType) {
        var values: [String: String] = [:]
        for field in PluginManager.shared.additionalConnectionFields(for: newType)
            where field.section == .advanced
        {
            if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        additionalFieldValues = values
    }

    func load(from connection: DatabaseConnection) {
        var values: [String: String] = [:]
        let allFields = PluginManager.shared.additionalConnectionFields(for: connection.type)
        for field in allFields where field.section == .advanced {
            if let value = connection.additionalFields[field.id] {
                values[field.id] = value
            } else if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        if connection.additionalFields["redisDatabase"] == nil,
           let rdb = connection.redisDatabase
        {
            values["redisDatabase"] = String(rdb)
        }
        additionalFieldValues = values
        startupCommands = connection.startupCommands ?? ""
        preConnectScript = connection.preConnectScript ?? ""
        aiPolicy = connection.aiPolicy
        externalAccess = connection.externalAccess
        localOnly = connection.localOnly
    }

    func write(into fields: inout [String: String]) {
        for (key, value) in additionalFieldValues {
            fields[key] = value
        }
    }
}
