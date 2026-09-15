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

    /// Which credentials this connection signs in with: its own, or a named profile shared with
    /// every other connection pointing at the same one.
    var credentialMode: CredentialMode = .inline
    var credentialProfiles: [CredentialProfile] = []

    /// What the keychain held when the form opened. An empty password field means the user cleared
    /// it only if there was something to clear and the read succeeded.
    private(set) var storedPasswordState: ConnectionStorage.StoredSecretState = .absent

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
        return PluginMetadataRegistry.shared.snapshot(for: type)?
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

    /// The user emptied a password field that had one in it. Saving then has to delete the stored
    /// secret: leaving it behind means the next connect still authenticates with the old password,
    /// an encrypted export still carries it, and a duplicate copies it.
    var clearsStoredPassword: Bool {
        !usesCredentialProfile && !effectivePromptForPassword && password.isEmpty && storedPasswordState == .stored
    }

    var usesCredentialProfile: Bool { credentialMode.profileId != nil }

    /// Enough to make a profile out of. A password-only engine such as Redis has no username, so
    /// requiring one hid the promotion exactly where it was most useful.
    var hasPromotableCredentials: Bool {
        !resolvedUsername.isEmpty || !password.isEmpty || effectivePromptForPassword
    }

    var selectedCredentialProfile: CredentialProfile? {
        guard let id = credentialMode.profileId else { return nil }
        return credentialProfiles.first { $0.id == id }
    }

    /// The connection points at a profile this Mac does not have, which an import or a sync that
    /// has not caught up can both produce.
    var credentialProfileIsMissing: Bool {
        usesCredentialProfile && selectedCredentialProfile == nil
    }

    var isSavingCredentialsAsProfile = false

    func loadCredentialProfiles() {
        credentialProfiles = CredentialProfileStorage.shared.loadProfiles()
    }

    /// Re-reads the profiles after they changed elsewhere, and drops a selection whose profile is
    /// gone. Storage has already given this connection those credentials inline, so keeping the
    /// dead id would write it back on the next save and undo that.
    func reconcileCredentialProfiles() {
        let storage = CredentialProfileStorage.shared
        credentialProfiles = storage.loadProfiles()
        guard !storage.lastLoadFailed,
              let id = credentialMode.profileId,
              !credentialProfiles.contains(where: { $0.id == id })
        else { return }
        credentialMode = .inline
        if let refreshed = coordinator?.value?.storage.loadConnection(id: coordinator?.value?.connectionId ?? UUID()) {
            username = refreshed.username
            promptForPassword = refreshed.promptForPassword
            storedPasswordState = coordinator?.value?.storage.passwordState(for: refreshed.id) ?? .absent
            password = coordinator?.value?.storage.loadPassword(for: refreshed.id) ?? ""
        }
    }

    /// The credentials currently typed into the form, as an unsaved profile for the editor to open
    /// with. Promoting what is already filled in beats making the user retype it.
    func profileFromCurrentCredentials() -> CredentialProfile {
        CredentialProfile(
            name: "",
            username: resolvedUsername,
            passwordMode: effectivePromptForPassword ? .prompt : .stored
        )
    }

    var usePgpass: Bool {
        additionalFieldValues["usePgpass"] == "true"
    }

    var validationIssues: [String] {
        var issues: [String] = []

        let profileFieldIds = Set(selectedCredentialProfile?.secureFieldIds ?? [])
        for field in authFields where field.isRequired && isFieldVisible(field) {
            /// A linked profile hides its own fields and supplies them at connect, so requiring the
            /// connection's empty copy leaves Save disabled with nothing on screen to fix.
            if profileFieldIds.contains(field.id) { continue }
            let value = additionalFieldValues[field.id] ?? field.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(format: String(localized: "%@ is required"), field.label))
            }
        }

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
        credentialMode = connection.credentialMode
        loadCredentialProfiles()

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

        storedPasswordState = storage.passwordState(for: connection.id)
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
