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

    var resolvedUsername: String {
        username.trimmingCharacters(in: .whitespaces)
    }

    var hidesBuiltInPassword: Bool {
        guard let type = coordinator?.value?.network.type else { return false }
        return PluginMetadataRegistry.shared.snapshot(forTypeId: type.pluginTypeId)?
            .connection.hidesBuiltInPassword ?? false
    }

    var hidesPassword: Bool {
        if hidesBuiltInPassword { return true }
        guard let type = coordinator?.value?.network.type else {
            return authFields.hidesPassword(forValues: additionalFieldValues)
        }
        return PluginManager.shared.additionalConnectionFields(for: type)
            .hidesPassword(forValues: additionalFieldValues)
    }

    var hidesUsername: Bool {
        guard let type = coordinator?.value?.network.type else {
            return authFields.hidesUsername(forValues: additionalFieldValues)
        }
        return PluginManager.shared.additionalConnectionFields(for: type)
            .hidesUsername(forValues: additionalFieldValues)
    }

    var effectivePromptForPassword: Bool {
        promptForPassword && !hidesPassword
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
        let type = coordinator?.value?.network.type ?? .mysql
        return PluginManager.shared.additionalConnectionFields(for: type)
            .isVisible(field, forValues: additionalFieldValues)
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
        if connection.type.pluginTypeId == "DuckDB",
           (values["duckdbFilePath"] ?? "").isEmpty,
           !connection.database.isEmpty {
            values["duckdbFilePath"] = connection.database
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
        pgpassStatus = PgpassStatus.check(
            host: coordinator.network.resolvedHost,
            port: coordinator.network.resolvedPort,
            database: coordinator.network.database,
            username: PgpassReader.effectiveUsername(resolvedUsername)
        )
    }
}
