//
//  CredentialProfileEditorSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// One credential profile: the name every connection picks it by, the username, and where the
/// password comes from.
struct CredentialProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingProfile: CredentialProfile?
    var initialPassword: String?
    /// Which engine's secrets to offer first, so a profile promoted from a Postgres connection
    /// does not open on MySQL's fields.
    var initialDatabaseType: DatabaseType?
    var onSave: ((CredentialProfile) -> Void)?
    var onDelete: (() -> Void)?

    @State private var name: String = ""
    @State private var username: String = ""
    @State private var passwordKind: PasswordKind = .stored
    @State private var password: String = ""
    @State private var revealsPassword = false
    @State private var sourceKind: PasswordSourceKind = .file
    @State private var sourceValue: String = ""
    @State private var sourceField: String = ""

    @State private var secureFieldType: DatabaseType = .mysql
    @State private var secureFieldValues: [String: String] = [:]

    @State private var showingDeleteConfirmation = false
    @State private var dependentCount = 0
    @State private var saveError: String?

    /// Read once when the sheet opens. `body` reads `nameIsUnique` and `isStored` several times per
    /// pass, and each one used to decode the whole profiles file off disk, on every keystroke.
    @State private var otherProfileNames: [String] = []
    @State private var isStored = false
    @State private var secureFields: [ConnectionField] = []
    /// False when a keychain read failed rather than finding nothing. Saving then must not
    /// treat an empty field as the user clearing a secret: a rename while the keychain was
    /// locked would delete the password of every connection on the profile.
    @State private var secretsWereReadable = true

    private var storage: CredentialProfileStorage { .shared }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var isValid: Bool {
        guard !trimmedName.isEmpty else { return false }
        guard nameIsUnique else { return false }
        if passwordKind == .source {
            return !sourceValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// Two profiles with one name are indistinguishable in every picker that offers them, which is
    /// the reason the system's own profile editors refuse it.
    private var nameIsUnique: Bool {
        !otherProfileNames.contains {
            $0.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Profile")) {
                    TextField(String(localized: "Name"), text: $name, prompt: Text("Production reader"))
                        .accessibilityIdentifier("credential-profile-name")
                    if !trimmedName.isEmpty && !nameIsUnique {
                        Label(
                            String(localized: "Another profile already has this name."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    }
                    TextField(String(localized: "Username"), text: $username, prompt: Text("app_reader"))
                        .accessibilityIdentifier("credential-profile-username")
                }

                if !secretsWereReadable {
                    Section {
                        Label(
                            String(localized: "The Keychain could not be read, so the stored secrets are not shown. Editing the name is safe; they are left as they are."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    }
                }
                passwordSection
                secureFieldsSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            bottomBar
        }
        .frame(minWidth: 480, idealHeight: 460)
        .onAppear(perform: load)
    }

    // MARK: - Password

    @ViewBuilder
    private var passwordSection: some View {
        Section(String(localized: "Password")) {
            Picker(String(localized: "Source"), selection: $passwordKind) {
                ForEach(PasswordKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityIdentifier("credential-profile-password-kind")

            switch passwordKind {
            case .stored:
                /// Revealing swaps the control rather than unmasking one: `NSSecureTextField` has
                /// no reveal of its own, and this is how the system's own password fields do it.
                if revealsPassword {
                    TextField(String(localized: "Password"), text: $password)
                } else {
                    SecureField(String(localized: "Password"), text: $password)
                }
                Toggle(String(localized: "Show password"), isOn: $revealsPassword)
            case .prompt:
                Text("Every connection using this profile asks for the password once each time TablePro runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .pgpass:
                Text("Looked up in ~/.pgpass by the host, port, database and username of whichever connection is opening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .source:
                Picker(String(localized: "Read From"), selection: $sourceKind) {
                    ForEach(PasswordSourceKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField(sourceKind.valueLabel, text: $sourceValue, prompt: Text(sourceKind.placeholder))
                if sourceKind == .vault {
                    TextField(String(localized: "Field"), text: $sourceField, prompt: Text("password"))
                }
                if sourceKind == .awsSecretsManager {
                    TextField(String(localized: "JSON Key"), text: $sourceField, prompt: Text("password"))
                }
                Text("Resolved on every connect. It stays on this Mac and never syncs, because it can name a command to run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Secure fields

    @ViewBuilder
    private var secureFieldsSection: some View {
        Section {
            Picker(String(localized: "For"), selection: $secureFieldType) {
                ForEach(DatabaseType.allKnownTypes, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .onChange(of: secureFieldType) { _, _ in reloadSecureFields() }
            if secureFields.isEmpty {
                Text("This database type signs in with the username and password above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(secureFields, id: \.id) { field in
                    ConnectionFieldRow(field: field, value: secureFieldBinding(for: field))
                }
            }
        } header: {
            Text(String(localized: "Additional Secrets"))
        } footer: {
            Text("A connection reads only the secrets its own database type declares, so one profile can carry several engines' keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadSecureFields() {
        secureFields = PluginManager.shared.additionalConnectionFields(for: secureFieldType).filter(\.isSecure)
    }

    private func secureFieldBinding(for field: ConnectionField) -> Binding<String> {
        Binding(
            get: { secureFieldValues[field.id] ?? "" },
            set: { secureFieldValues[field.id] = $0 }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if isStored {
                Button(role: .destructive) {
                    dependentCount = storage.connectionsUsing(existingProfile?.id ?? UUID()).count
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete Profile")
                }
                .accessibilityIdentifier("credential-profile-delete")
                .alert(String(localized: "Delete Credential Profile?"), isPresented: $showingDeleteConfirmation) {
                    Button(String(localized: "Delete"), role: .destructive) { deleteProfile() }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    if dependentCount > 0 {
                        Text("^[\(dependentCount) connection](inflect: true) use this profile. They keep these credentials as their own.")
                    } else {
                        Text("This profile will be permanently deleted.")
                    }
                }
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()

            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("credential-profile-cancel")
            Button(isStored ? String(localized: "Save") : String(localized: "Create")) { saveProfile() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .accessibilityIdentifier("credential-profile-save")
        }
        .padding()
    }

    // MARK: - Actions

    private func load() {
        let profiles = storage.loadProfiles()
        otherProfileNames = profiles.filter { $0.id != existingProfile?.id }.map { $0.name }
        isStored = existingProfile.map { candidate in profiles.contains { $0.id == candidate.id } } ?? false
        if let initialDatabaseType {
            secureFieldType = initialDatabaseType
        }
        reloadSecureFields()

        guard let profile = existingProfile else { return }
        name = profile.name
        username = profile.username
        for fieldId in profile.secureFieldIds {
            if let value = storage.loadSecureField(fieldId: fieldId, for: profile.id) {
                secureFieldValues[fieldId] = value
            } else {
                secretsWereReadable = false
            }
        }

        switch profile.passwordMode {
        case .stored:
            passwordKind = .stored
            if let stored = storage.loadPassword(for: profile.id) {
                password = stored
            } else if let initialPassword {
                password = initialPassword
            } else if isStored {
                secretsWereReadable = false
            }
        case .prompt:
            passwordKind = .prompt
        case .pgpass:
            passwordKind = .pgpass
        case .source(let source):
            passwordKind = .source
            (sourceKind, sourceValue, sourceField) = Self.decompose(source)
        }
    }

    private func saveProfile() {
        let profileId = existingProfile?.id ?? UUID()
        let liveFields = secureFieldValues.filter { !$0.value.isEmpty }
        let profile = CredentialProfile(
            id: profileId,
            name: trimmedName,
            username: username.trimmingCharacters(in: .whitespaces),
            passwordMode: buildPasswordMode(),
            secureFieldIds: secretsWereReadable
                ? liveFields.keys.sorted()
                : Array(Set(existingProfile?.secureFieldIds ?? []).union(liveFields.keys)).sorted(),
            sortOrder: existingProfile?.sortOrder ?? 0
        )

        let persisted = isStored ? storage.updateProfile(profile) : storage.addProfile(profile)
        /// The keychain writes below are keyed by the profile id, so running them for a profile
        /// that never reached disk would leave secrets nothing can name.
        guard persisted else {
            saveError = String(localized: "Could not save the profile. Check disk space and permissions, then try again.")
            return
        }
        saveError = nil

        if case .stored = profile.passwordMode, !password.isEmpty {
            guard storage.savePassword(password, for: profileId) else {
                saveError = String(localized: "Could not save the password to the Keychain. Nothing was changed.")
                return
            }
        } else if secretsWereReadable {
            storage.deletePassword(for: profileId)
        }

        /// Only what was read back is eligible for deletion. A field whose value could not be read
        /// is still there and still in use.
        if secretsWereReadable {
            let removed = Set(existingProfile?.secureFieldIds ?? []).subtracting(liveFields.keys)
            for fieldId in removed {
                storage.deleteSecureField(fieldId: fieldId, for: profileId)
            }
        }
        for (fieldId, value) in liveFields where !storage.saveSecureField(value, fieldId: fieldId, for: profileId) {
            saveError = String(localized: "Could not save a secret to the Keychain. Nothing was changed.")
            return
        }

        onSave?(profile)
        dismiss()
    }

    private func buildPasswordMode() -> CredentialPasswordMode {
        switch passwordKind {
        case .stored: .stored
        case .prompt: .prompt
        case .pgpass: .pgpass
        case .source: .source(sourceKind.source(value: sourceValue, field: sourceField))
        }
    }

    private func deleteProfile() {
        guard let profile = existingProfile else { return }
        guard storage.deleteProfile(profile) else {
            saveError = String(localized: "Could not delete the profile. Check disk space and permissions, then try again.")
            return
        }
        onDelete?()
        dismiss()
    }

    private static func decompose(_ source: PasswordSource) -> (PasswordSourceKind, String, String) {
        switch source {
        case .file(let path): (.file, path, "")
        case .env(let variable): (.env, variable, "")
        case .command(let shell): (.command, shell, "")
        case .onePassword(let reference): (.onePassword, reference, "")
        case .vault(let path, let field): (.vault, path, field)
        case .awsSecretsManager(let secretId, let jsonKey): (.awsSecretsManager, secretId, jsonKey ?? "")
        }
    }
}

// MARK: - Kinds

extension CredentialProfileEditorSheet {
    enum PasswordKind: String, CaseIterable, Identifiable {
        case stored, prompt, pgpass, source

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .stored: String(localized: "Saved in the Keychain")
            case .prompt: String(localized: "Ask every time")
            case .pgpass: String(localized: "~/.pgpass")
            case .source: String(localized: "Read from elsewhere")
            }
        }
    }

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

        func source(value: String, field: String) -> PasswordSource {
            let trimmedValue = value.trimmingCharacters(in: .whitespaces)
            let trimmedField = field.trimmingCharacters(in: .whitespaces)
            switch self {
            case .file: return .file(path: trimmedValue)
            case .env: return .env(variable: trimmedValue)
            case .command: return .command(shell: value)
            case .onePassword: return .onePassword(reference: trimmedValue)
            case .vault: return .vault(path: trimmedValue, field: trimmedField)
            case .awsSecretsManager:
                return .awsSecretsManager(secretId: trimmedValue, jsonKey: trimmedField.isEmpty ? nil : trimmedField)
            }
        }
    }
}
