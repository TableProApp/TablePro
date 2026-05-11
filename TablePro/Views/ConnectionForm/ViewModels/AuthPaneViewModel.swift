//
//  AuthPaneViewModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum PgpassStatus {
    case notChecked
    case fileNotFound
    case badPermissions
    case matchFound
    case noMatch

    static func check(host: String, port: Int, database: String, username: String) -> PgpassStatus {
        guard PgpassReader.fileExists() else { return .fileNotFound }
        guard PgpassReader.filePermissionsAreValid() else { return .badPermissions }
        if PgpassReader.resolve(host: host, port: port, database: database, username: username) != nil {
            return .matchFound
        }
        return .noMatch
    }
}

@Observable
@MainActor
final class AuthPaneViewModel {
    var username: String = ""
    var password: String = ""
    var promptForPassword: Bool = false
    var additionalFieldValues: [String: String] = [:]
    var pgpassStatus: PgpassStatus = .notChecked

    var coordinator: WeakCoordinatorRef?

    var authFields: [ConnectionField] {
        guard let type = coordinator?.value?.network.type else { return [] }
        return PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .authentication }
    }

    var hidesPassword: Bool {
        authFields.contains { field in
            guard field.hidesPassword else { return false }
            if case .toggle = field.fieldType {
                return additionalFieldValues[field.id] == "true"
            }
            return true
        }
    }

    var usePgpass: Bool {
        additionalFieldValues["usePgpass"] == "true"
    }

    var validationIssues: [String] {
        var issues: [String] = []

        for field in authFields where field.isRequired && isFieldVisible(field) {
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
        let currentValue = additionalFieldValues[rule.fieldId]
            ?? coordinator?.value?.network.additionalFieldValues[rule.fieldId]
            ?? defaultValue
        return rule.values.contains(currentValue)
    }

    func resetForType(_ newType: DatabaseType) {
        var values: [String: String] = [:]
        for field in PluginManager.shared.additionalConnectionFields(for: newType)
            where field.section == .authentication
        {
            if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        additionalFieldValues = values
        pgpassStatus = .notChecked
    }

    func load(from connection: DatabaseConnection, storage: ConnectionStorage) {
        username = connection.username
        promptForPassword = connection.promptForPassword

        var values: [String: String] = [:]
        let allFields = PluginManager.shared.additionalConnectionFields(for: connection.type)
        for field in allFields where field.section == .authentication {
            if let value = connection.additionalFields[field.id] {
                values[field.id] = value
            } else if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        for field in allFields where field.section == .authentication && field.isSecure {
            if let secureValue = storage.loadPluginSecureField(fieldId: field.id, for: connection.id) {
                values[field.id] = secureValue
            }
        }
        additionalFieldValues = values

        if let savedPassword = storage.loadPassword(for: connection.id) {
            password = savedPassword
        }
    }

    func write(into fields: inout [String: String]) {
        for (key, value) in additionalFieldValues {
            fields[key] = value
        }
    }

    func updatePgpassStatus() {
        guard let coordinator = coordinator?.value else { return }
        guard usePgpass else {
            pgpassStatus = .notChecked
            return
        }
        let host = coordinator.network.host.isEmpty ? "localhost" : coordinator.network.host
        let port = Int(coordinator.network.port) ?? coordinator.network.type.defaultPort
        let database = coordinator.network.database
        let username = self.username.isEmpty ? "root" : self.username
        pgpassStatus = PgpassStatus.check(host: host, port: port, database: database, username: username)
    }
}
