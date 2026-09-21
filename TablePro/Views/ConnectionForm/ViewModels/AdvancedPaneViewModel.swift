//
//  AdvancedPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

@MainActor
final class AdvancedPaneViewModel: ObservableObject {
    @Published var additionalFieldValues: [String: String] = [:]
    @Published var startupCommands: String = ""
    @Published var preConnectScript: String = ""
    @Published var externalAccess: ExternalAccessLevel = .readOnly
    @Published var localOnly: Bool = false
    @Published var aiPolicy: AIConnectionPolicy?

    @Published var coordinator: WeakCoordinatorRef?

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
        issues += advancedFields.filter(isFieldVisible).compactMap { $0.rangeIssue(in: additionalFieldValues[$0.id] ?? "") }
        return issues
    }

    func isFieldVisible(_ field: ConnectionField) -> Bool {
        let type = coordinator?.value?.network.type ?? .mysql
        let values = coordinator?.value?.allAdditionalFieldValues ?? additionalFieldValues
        return PluginFieldRendering.isFieldVisible(field, type: type, values: values)
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
