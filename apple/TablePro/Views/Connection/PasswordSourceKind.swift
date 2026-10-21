//
//  PasswordSourceKind.swift
//  TablePro
//

import Foundation

enum PasswordSourceKind: String, CaseIterable, Identifiable {
    case file, env, command, onePassword, vault, awsSecretsManager, vaultDatabaseRole

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .file: String(localized: "A file")
        case .env: String(localized: "An environment variable")
        case .command: String(localized: "The output of a command")
        case .onePassword: "1Password"
        case .vault: "HashiCorp Vault"
        case .awsSecretsManager: "AWS Secrets Manager"
        case .vaultDatabaseRole: String(localized: "HashiCorp Vault database role")
        }
    }

    // The source answers for the username as well as the password.
    var suppliesUsername: Bool { self == .vaultDatabaseRole }

    var valueLabel: String {
        switch self {
        case .file: String(localized: "Path")
        case .env: String(localized: "Variable")
        case .command: String(localized: "Command")
        case .onePassword: String(localized: "Reference")
        case .vault: String(localized: "Path")
        case .awsSecretsManager: String(localized: "Secret ID")
        case .vaultDatabaseRole: String(localized: "Mount")
        }
    }

    var fieldLabel: String? {
        switch self {
        case .vault: String(localized: "Field")
        case .awsSecretsManager: String(localized: "JSON Key")
        case .vaultDatabaseRole: String(localized: "Role")
        case .file, .env, .command, .onePassword: nil
        }
    }

    var fieldPlaceholder: String {
        self == .vaultDatabaseRole ? "readonly" : "password"
    }

    var placeholder: String {
        switch self {
        case .file: "~/.secrets/db-password"
        case .env: "DB_PASSWORD"
        case .command: "security find-generic-password -w -s db"
        case .onePassword: "op://vault/item/password"
        case .vault: "secret/data/db"
        case .awsSecretsManager: "prod/db/credentials"
        case .vaultDatabaseRole: "database"
        }
    }

    // `vaultAccess` carries what a Vault database role needs beyond its mount and role.
    func source(
        value: String,
        field: String,
        reuseSeconds: Int?,
        vaultAccess: VaultAccessDraft = VaultAccessDraft()
    ) -> PasswordSource {
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
        case .vaultDatabaseRole:
            return .vaultDatabaseRole(VaultDatabaseRole(
                address: vaultAccess.trimmedAddress,
                mount: trimmedValue,
                role: trimmedField,
                auth: vaultAccess.auth
            ))
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
        case .vaultDatabaseRole(let role): (.vaultDatabaseRole, role.mount, role.role)
        }
    }
}

// The Vault address and sign-in method of a database role, as the profile editor holds them.
struct VaultAccessDraft: Equatable {
    enum Method: String, CaseIterable, Identifiable {
        case token, appRole, oidc

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .token: String(localized: "Token")
            case .appRole: "AppRole"
            case .oidc: "OIDC"
            }
        }

        var defaultMount: String {
            switch self {
            case .token: ""
            case .appRole: VaultAuthMethod.defaultAppRoleMount
            case .oidc: VaultAuthMethod.defaultOIDCMount
            }
        }
    }

    var address = ""
    var method: Method = .token
    var mount = ""
    var roleId = ""
    var secretIdPath = ""
    var oidcRole = ""

    init() {}

    init(_ role: VaultDatabaseRole) {
        address = role.address ?? ""
        switch role.auth {
        case .token:
            method = .token
        case let .appRole(mount, roleId, secretIdPath):
            method = .appRole
            self.mount = mount == VaultAuthMethod.defaultAppRoleMount ? "" : mount
            self.roleId = roleId
            self.secretIdPath = secretIdPath
        case let .oidc(mount, role):
            method = .oidc
            self.mount = mount == VaultAuthMethod.defaultOIDCMount ? "" : mount
            oidcRole = role
        }
    }

    // The auth mount belongs to the method it was typed for.
    mutating func selectMethod(_ newMethod: Method) {
        guard newMethod != method else { return }
        method = newMethod
        mount = ""
    }

    var trimmedAddress: String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var auth: VaultAuthMethod {
        let trimmedMount = mount.trimmingCharacters(in: .whitespaces)
        let effectiveMount = trimmedMount.isEmpty ? method.defaultMount : trimmedMount
        switch method {
        case .token:
            return .token
        case .appRole:
            return .appRole(
                mount: effectiveMount,
                roleId: roleId.trimmingCharacters(in: .whitespaces),
                secretIdPath: secretIdPath.trimmingCharacters(in: .whitespaces)
            )
        case .oidc:
            return .oidc(mount: effectiveMount, role: oidcRole.trimmingCharacters(in: .whitespaces))
        }
    }

    var isComplete: Bool {
        guard case let .appRole(_, roleId, secretIdPath) = auth else { return true }
        return !roleId.isEmpty && !secretIdPath.isEmpty
    }
}
