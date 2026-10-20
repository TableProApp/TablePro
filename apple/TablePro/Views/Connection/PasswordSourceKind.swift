//
//  PasswordSourceKind.swift
//  TablePro
//

import Foundation

enum PasswordSourceKind: String, CaseIterable, Identifiable {
    case file, env, command, onePassword, vault, awsSecretsManager

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .file: String(localized: "A file")
        case .env: String(localized: "An environment variable")
        case .command: String(localized: "The output of a command")
        case .onePassword: "1Password"
        case .vault: "HashiCorp Vault"
        case .awsSecretsManager: "AWS Secrets Manager"
        }
    }

    var valueLabel: String {
        switch self {
        case .file: String(localized: "Path")
        case .env: String(localized: "Variable")
        case .command: String(localized: "Command")
        case .onePassword: String(localized: "Reference")
        case .vault: String(localized: "Path")
        case .awsSecretsManager: String(localized: "Secret ID")
        }
    }

    var fieldLabel: String? {
        switch self {
        case .vault: String(localized: "Field")
        case .awsSecretsManager: String(localized: "JSON Key")
        case .file, .env, .command, .onePassword: nil
        }
    }

    var placeholder: String {
        switch self {
        case .file: "~/.secrets/db-password"
        case .env: "DB_PASSWORD"
        case .command: "security find-generic-password -w -s db"
        case .onePassword: "op://vault/item/password"
        case .vault: "secret/data/db"
        case .awsSecretsManager: "prod/db/credentials"
        }
    }

    func source(value: String, field: String, reuseSeconds: Int?) -> PasswordSource {
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
        let trimmedField = field.trimmingCharacters(in: .whitespaces)
        switch self {
        case .file: return .file(path: trimmedValue)
        case .env: return .env(variable: trimmedValue)
        case .command: return .command(shell: value, reuseSeconds: reuseSeconds)
        case .onePassword: return .onePassword(reference: trimmedValue)
        case .vault: return .vault(path: trimmedValue, field: trimmedField)
        case .awsSecretsManager:
            return .awsSecretsManager(secretId: trimmedValue, jsonKey: trimmedField.isEmpty ? nil : trimmedField)
        }
    }

    static func decompose(_ source: PasswordSource) -> (kind: PasswordSourceKind, value: String, field: String) {
        switch source {
        case .file(let path): (.file, path, "")
        case .env(let variable): (.env, variable, "")
        case .command(let shell, _): (.command, shell, "")
        case .onePassword(let reference): (.onePassword, reference, "")
        case .vault(let path, let field): (.vault, path, field)
        case .awsSecretsManager(let secretId, let jsonKey): (.awsSecretsManager, secretId, jsonKey ?? "")
        }
    }
}
