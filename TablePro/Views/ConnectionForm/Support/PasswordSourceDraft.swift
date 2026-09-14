//
//  PasswordSourceDraft.swift
//  TablePro
//

import Foundation

/// Where the connection form says a password comes from.
///
/// One picker rather than a toggle beside a field, because the choices are exclusive and the old
/// pair could express a state the connect path cannot honour: a prompt toggle on and a password
/// source set means `resolvePassword` runs the source and the prompt never appears.
enum PasswordSourceMode: String, CaseIterable, Identifiable {
    case keychain
    case prompt
    case sharedTemplate
    case command
    case onePassword
    case vault
    case awsSecretsManager
    case file
    case environment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keychain: return String(localized: "Save in Keychain")
        case .prompt: return String(localized: "Ask every time")
        case .sharedTemplate: return String(localized: "Shared secret manager command")
        case .command: return String(localized: "Shell command")
        case .onePassword: return "1Password"
        case .vault: return "HashiCorp Vault"
        case .awsSecretsManager: return "AWS Secrets Manager"
        case .file: return String(localized: "File")
        case .environment: return String(localized: "Environment variable")
        }
    }

    /// Whether the mode runs something outside TablePro to fetch the password. These are the modes
    /// the resolved-password cache holds and the ones the form can preview a command for.
    var isExternal: Bool {
        switch self {
        case .keychain, .prompt: return false
        case .sharedTemplate, .command, .onePassword, .vault, .awsSecretsManager, .file, .environment: return true
        }
    }
}

/// The form's editable copy of a connection's `PasswordSource`, kept as one field per mode so
/// switching modes and switching back does not throw away what the user typed.
struct PasswordSourceDraft: Equatable {
    var mode: PasswordSourceMode = .keychain
    var command: String = ""
    var onePasswordReference: String = ""
    var vaultPath: String = ""
    var vaultField: String = "password"
    var awsSecretId: String = ""
    var awsJsonKey: String = ""
    var filePath: String = ""
    var environmentVariable: String = ""

    static let keychain = PasswordSourceDraft()

    init() {}

    init(source: PasswordSource?, promptsForPassword: Bool) {
        guard let source else {
            mode = promptsForPassword ? .prompt : .keychain
            return
        }
        switch source {
        case let .file(path):
            mode = .file
            filePath = path
        case let .env(variable):
            mode = .environment
            environmentVariable = variable
        case let .command(shell):
            mode = .command
            command = shell
        case .sharedTemplate:
            mode = .sharedTemplate
        case let .onePassword(reference):
            mode = .onePassword
            onePasswordReference = reference
        case let .vault(path, field):
            mode = .vault
            vaultPath = path
            vaultField = field
        case let .awsSecretsManager(secretId, jsonKey):
            mode = .awsSecretsManager
            awsSecretId = secretId
            awsJsonKey = jsonKey ?? ""
        }
    }

    /// Nil for the two modes TablePro answers itself, and nil for an external mode whose own field
    /// is still blank: a half-filled source saved as one would fail at connect time with a message
    /// about the tool rather than about the empty field, and `validationIssue` blocks that save.
    var passwordSource: PasswordSource? {
        switch mode {
        case .keychain, .prompt:
            return nil
        case .sharedTemplate:
            return .sharedTemplate
        case .command:
            return trimmed(command).map { .command(shell: $0) }
        case .onePassword:
            return trimmed(onePasswordReference).map { .onePassword(reference: $0) }
        case .vault:
            guard let path = trimmed(vaultPath) else { return nil }
            return .vault(path: path, field: trimmed(vaultField) ?? "password")
        case .awsSecretsManager:
            guard let secretId = trimmed(awsSecretId) else { return nil }
            return .awsSecretsManager(secretId: secretId, jsonKey: trimmed(awsJsonKey))
        case .file:
            return trimmed(filePath).map { .file(path: $0) }
        case .environment:
            return trimmed(environmentVariable).map { .env(variable: $0) }
        }
    }

    var promptsForPassword: Bool {
        mode == .prompt
    }

    var validationIssue: String? {
        switch mode {
        case .keychain, .prompt, .sharedTemplate:
            return nil
        case .command where passwordSource == nil:
            return String(localized: "Enter the shell command that prints the password.")
        case .onePassword where passwordSource == nil:
            return String(localized: "Enter the 1Password secret reference.")
        case .vault where passwordSource == nil:
            return String(localized: "Enter the Vault secret path.")
        case .awsSecretsManager where passwordSource == nil:
            return String(localized: "Enter the AWS secret ID.")
        case .file where passwordSource == nil:
            return String(localized: "Enter the path to the password file.")
        case .environment where passwordSource == nil:
            return String(localized: "Enter the environment variable name.")
        default:
            return nil
        }
    }

    private func trimmed(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
