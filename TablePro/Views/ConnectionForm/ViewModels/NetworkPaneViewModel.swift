//
//  NetworkPaneViewModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@Observable
@MainActor
final class NetworkPaneViewModel {
    var name: String = ""
    var type: DatabaseType = .mysql
    var host: String = ""
    var port: String = ""
    var database: String = ""
    var additionalFieldValues: [String: String] = [:]

    var coordinator: WeakCoordinatorRef?

    var connectionMode: ConnectionMode {
        PluginManager.shared.connectionMode(for: type)
    }

    var connectionFields: [ConnectionField] {
        PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .connection }
    }

    var hasHostListField: Bool {
        connectionFields.contains { field in
            guard case .hostList = field.fieldType else { return false }
            return isFieldVisible(field)
        }
    }

    var defaultPort: String {
        let port = type.defaultPort
        return port == 0 ? "" : String(port)
    }

    var supportsDatabaseField: Bool {
        let mode = connectionMode
        return mode == .fileBased
            || (mode == .apiOnly && PluginManager.shared.supportsDatabaseSwitching(for: type))
            || (mode == .network && PluginManager.shared.requiresAuthentication(for: type))
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "Connection name is required"))
        }
        let mode = connectionMode
        let needsDatabaseField = mode == .fileBased
            || (mode == .apiOnly && PluginManager.shared.supportsDatabaseSwitching(for: type))
        if needsDatabaseField && database.trimmingCharacters(in: .whitespaces).isEmpty {
            let label = mode == .fileBased
                ? String(localized: "Database file path is required")
                : String(localized: "Database name is required")
            issues.append(label)
        }
        for field in connectionFields where field.isRequired && isFieldVisible(field) {
            let value = additionalFieldValues[field.id] ?? field.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(format: String(localized: "%@ is required"), field.label))
            }
        }
        return issues
    }

    func setType(_ newType: DatabaseType) {
        guard newType != type else { return }
        type = newType
        coordinator?.value?.didChangeType(newType)
    }

    func applyTypeDefaults(forNewType newType: DatabaseType) {
        port = String(newType.defaultPort)
        var values: [String: String] = [:]
        for field in PluginManager.shared.additionalConnectionFields(for: newType)
            where field.section == .connection
        {
            if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        additionalFieldValues = values
    }

    func applyNameSuggestionIfEmpty(_ suggestion: String) {
        guard name.isEmpty else { return }
        name = suggestion
    }

    func isFieldVisible(_ field: ConnectionField) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        let allFields = PluginManager.shared.additionalConnectionFields(for: type)
        let defaultValue = allFields.first { $0.id == rule.fieldId }?.defaultValue ?? ""
        let currentValue = additionalFieldValues[rule.fieldId] ?? defaultValue
        return rule.values.contains(currentValue)
    }

    func load(from connection: DatabaseConnection) {
        name = connection.name
        host = connection.host
        port = connection.port > 0 ? String(connection.port) : ""
        database = connection.database
        type = connection.type

        var values: [String: String] = [:]
        let allFields = PluginManager.shared.additionalConnectionFields(for: connection.type)
        for field in allFields where field.section == .connection {
            if let value = connection.additionalFields[field.id] {
                values[field.id] = value
            } else if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        if connection.type.pluginTypeId == "MongoDB",
           (values["mongoHosts"] ?? "").isEmpty
        {
            let existingHost = connection.host.isEmpty ? "localhost" : connection.host
            values["mongoHosts"] = "\(existingHost):\(connection.port)"
        }
        additionalFieldValues = values
    }

    func write(into fields: inout [String: String]) {
        for (key, value) in additionalFieldValues {
            fields[key] = value
        }
    }
}
