import SwiftUI
import TableProPluginKit

struct CredentialProfileDraft: Equatable {
    var name = ""
    var username = ""
    var passwordKind: CredentialPasswordKind = .stored
    var password = ""
    var sourceKind: PasswordSourceKind = .file
    var sourceValue = ""
    var sourceField = ""
    var commandReuseSeconds: Int?
    var vaultAccess = VaultAccessDraft()
    var secureFieldValues: [String: String] = [:]
    var takenNames: [String] = []

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespaces)
    }

    // Two profiles with one name are indistinguishable in every picker that offers them.
    var nameIsTaken: Bool {
        !trimmedName.isEmpty && takenNames.contains { ProfileNames.matches($0, trimmedName) }
    }

    var usernameComesFromSource: Bool {
        passwordKind == .source && sourceKind.suppliesUsername
    }

    var testedSource: PasswordSource? {
        guard !sourceValue.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if sourceKind == .vaultDatabaseRole {
            guard !sourceField.trimmingCharacters(in: .whitespaces).isEmpty, vaultAccess.isComplete else { return nil }
        }
        return sourceKind.source(value: sourceValue, field: sourceField, reuseSeconds: nil, vaultAccess: vaultAccess)
    }

    var passwordMode: CredentialPasswordMode {
        switch passwordKind {
        case .stored: .stored
        case .prompt: .prompt
        case .pgpass: .pgpass
        case .source:
            .source(sourceKind.source(
                value: sourceValue,
                field: sourceField,
                reuseSeconds: commandReuseSeconds,
                vaultAccess: vaultAccess
            ))
        }
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if trimmedName.isEmpty {
            issues.append(String(localized: "A profile needs a name."))
        } else if nameIsTaken {
            issues.append(String(localized: "Another profile already has this name."))
        }
        if passwordKind == .source, testedSource == nil {
            issues.append(String(localized: "Enter where the password is read from."))
        }
        return issues
    }

    mutating func apply(_ mode: CredentialPasswordMode) {
        passwordKind = mode.kind
        guard case .source(let source) = mode else { return }
        (sourceKind, sourceValue, sourceField) = PasswordSourceKind.decompose(source)
        if case .command(_, let reuseSeconds) = source {
            commandReuseSeconds = reuseSeconds
        }
        if let role = source.vaultDatabaseRole {
            vaultAccess = VaultAccessDraft(role)
        }
    }
}

struct CredentialProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingProfile: CredentialProfile?
    var initialPassword: String?
    // A profile promoted from a Postgres connection opens on Postgres's secrets, not MySQL's.
    var initialDatabaseType: DatabaseType?
    var onSave: ((CredentialProfile) -> Void)?
    var onDelete: (() -> Void)?

    @State private var draft = CredentialProfileDraft()
    @State private var baseline = CredentialProfileDraft()
    @State private var hasLoaded = false
    @State private var isStored = false
    // A new profile keeps this id when saved, so its first connect signs in as the user Test Source leased.
    @State private var draftProfileId = UUID()
    @State private var storedPasswordMode: CredentialPasswordMode?
    @State private var passwordRead: ProfileSecretRead = .absent
    @State private var fieldReads: [String: ProfileSecretRead] = [:]
    @State private var passwordWasPrefilled = false
    @State private var usageUnknown = false
    @State private var vaultAddressPrompt = "https://vault.example.com:8200"

    @State private var secureFieldTypes: [DatabaseType] = []
    @State private var secureFieldsByType: [DatabaseType: [ConnectionField]] = [:]
    @State private var secureFieldType: DatabaseType = .mysql

    @State private var pendingDeletion: PendingProfileDeletion?
    @State private var saveError: String?

    private var storage: CredentialProfileStorage { .shared }

    private var profileId: UUID {
        existingProfile?.id ?? draftProfileId
    }

    // A rename while the Keychain was locked must not read an empty field as the user clearing a secret.
    private var secretsWereReadable: Bool {
        passwordRead != .unreadable && !fieldReads.values.contains(.unreadable)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                profileSection
                if !secretsWereReadable {
                    Section {
                        NoticeLabel(
                            String(localized: "The Keychain could not be read, so the stored secrets are not shown. Editing the name is safe; they are left as they are.")
                        )
                    }
                }
                passwordSection
                if !secureFieldTypes.isEmpty {
                    secureFieldsSection
                }
            }
            .formStyle(.grouped)

            Divider()
            bottomBar
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 440, idealHeight: 560)
        .onAppear(perform: load)
    }

    private var profileSection: some View {
        Section(String(localized: "Profile")) {
            TextField(text: $draft.name, prompt: Text("Production reader")) {
                Text("Name")
                if draft.nameIsTaken {
                    NoticeLabel(String(localized: "Another profile already has this name."))
                }
            }
            .accessibilityIdentifier("credential-profile-name")
            TextField(
                String(localized: "Username"),
                text: $draft.username,
                prompt: draft.usernameComesFromSource ? Text("Generated by Vault") : Text(verbatim: "app_reader")
            )
            .disabled(draft.usernameComesFromSource)
            .accessibilityIdentifier("credential-profile-username")
        }
    }

    private var passwordSection: some View {
        Section(String(localized: "Password")) {
            Picker(selection: $draft.passwordKind) {
                ForEach(CredentialPasswordKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            } label: {
                Text("Source")
                Text(passwordKindHelp)
            }
            .accessibilityIdentifier("credential-profile-password-kind")

            switch draft.passwordKind {
            case .stored:
                RevealablePasswordField(
                    title: String(localized: "Password"),
                    text: $draft.password,
                    requiresAuthentication: passwordWasPrefilled
                )
            case .prompt, .pgpass:
                EmptyView()
            case .source:
                sourceRows
            }
        }
    }

    private var passwordKindHelp: String {
        switch draft.passwordKind {
        case .source where draft.sourceKind == .vaultDatabaseRole:
            String(localized: "It stays on this Mac and never syncs, because it names where your Vault token is sent.")
        default:
            draft.passwordKind.help
        }
    }

    @ViewBuilder private var sourceRows: some View {
        Picker(selection: $draft.sourceKind) {
            ForEach(PasswordSourceKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        } label: {
            Text("Read From")
            if draft.sourceKind == .vaultDatabaseRole {
                Text(String(localized: """
                    Connections on this profile share one database user. TablePro renews its lease while in use, revokes it \
                    once the last connection disconnects or after 10 minutes unused, and never saves the generated password.
                    """))
            }
        }
        TextField(text: $draft.sourceValue, prompt: Text(verbatim: draft.sourceKind.placeholder)) {
            Text(verbatim: draft.sourceKind.valueLabel)
            if draft.sourceKind == .command {
                Text(String(localized: """
                    {host}, {port}, {user} and {database} become the opening connection's values, \
                    already quoted. The command also gets them as TABLEPRO_HOST, TABLEPRO_PORT, \
                    TABLEPRO_USER and TABLEPRO_DATABASE.
                    """))
            }
        }
        if let fieldLabel = draft.sourceKind.fieldLabel {
            TextField(fieldLabel, text: $draft.sourceField, prompt: Text(verbatim: draft.sourceKind.fieldPlaceholder))
        }
        if draft.sourceKind == .vaultDatabaseRole {
            vaultAccessRows
        }
        if draft.sourceKind == .command {
            Picker(String(localized: "Reuse Result For"), selection: $draft.commandReuseSeconds) {
                Text("Never").tag(Int?.none)
                ForEach(Self.reuseChoices(including: draft.commandReuseSeconds), id: \.self) { seconds in
                    Text(verbatim: SettingsFormat.duration(seconds: seconds)).tag(Int?.some(seconds))
                }
            }
            .accessibilityIdentifier("credential-profile-command-reuse")
        }
        if let testedSource = draft.testedSource {
            PasswordSourceTestView(
                source: testedSource,
                context: { testContext },
                leaseOwner: { profileId },
                refusal: {
                    Self.testRefusal(
                        for: testedSource,
                        storedSource: storedSource,
                        storeIsTrusted: storage.storeIsTrusted
                    )
                }
            )
            if draft.sourceKind == .command, mentionsConnectionDetails {
                SettingsHelpRow("A test here has no connection to take the host, port and database from.")
            }
        }
    }

    @ViewBuilder private var vaultAccessRows: some View {
        TextField(
            String(localized: "Vault Address"),
            text: $draft.vaultAccess.address,
            prompt: Text(verbatim: vaultAddressPrompt)
        )
        .accessibilityIdentifier("credential-profile-vault-address")
        Picker(selection: vaultMethod) {
            ForEach(VaultAccessDraft.Method.allCases) { method in
                Text(method.displayName).tag(method)
            }
        } label: {
            Text("Sign In With")
            switch draft.vaultAccess.method {
            case .token:
                Text("Reads VAULT_TOKEN, or ~/.vault-token from vault login.")
            case .oidc:
                Text("Your browser opens to sign in once per launch. The role must allow http://localhost:8250/oidc/callback.")
            case .appRole:
                EmptyView()
            }
        }
        .accessibilityIdentifier("credential-profile-vault-method")
        switch draft.vaultAccess.method {
        case .token:
            EmptyView()
        case .appRole:
            TextField(String(localized: "Role ID"), text: $draft.vaultAccess.roleId)
                .accessibilityIdentifier("credential-profile-vault-role-id")
            TextField(
                String(localized: "Secret ID File"),
                text: $draft.vaultAccess.secretIdPath,
                prompt: Text(verbatim: "~/.vault/approle-secret-id")
            )
            .accessibilityIdentifier("credential-profile-vault-secret-id-path")
            TextField(
                String(localized: "Auth Mount"),
                text: $draft.vaultAccess.mount,
                prompt: Text(verbatim: VaultAuthMethod.defaultAppRoleMount)
            )
        case .oidc:
            TextField(String(localized: "OIDC Role"), text: $draft.vaultAccess.oidcRole, prompt: Text("Default role"))
            TextField(
                String(localized: "Auth Mount"),
                text: $draft.vaultAccess.mount,
                prompt: Text(verbatim: VaultAuthMethod.defaultOIDCMount)
            )
        }
    }

    // Choosing a method also resets the fields it does not use, in one write.
    private var vaultMethod: Binding<VaultAccessDraft.Method> {
        Binding(
            get: { draft.vaultAccess.method },
            set: { draft.vaultAccess.selectMethod($0) }
        )
    }

    private var secureFieldsSection: some View {
        Section(String(localized: "Additional Secrets")) {
            Picker(selection: $secureFieldType) {
                ForEach(secureFieldTypes, id: \.self) { type in
                    Text(verbatim: type.displayName).tag(type)
                }
            } label: {
                Text("Database")
                Text("A connection reads only the secrets its own database type declares, so one profile can carry several engines' keys.")
            }
            .accessibilityIdentifier("credential-profile-secure-field-type")
            ForEach(secureFieldsByType[secureFieldType] ?? [], id: \.id) { field in
                ConnectionFieldRow(field: field, value: secureFieldBinding(for: field))
            }
        }
    }

    private func secureFieldBinding(for field: ConnectionField) -> Binding<String> {
        Binding(
            get: { draft.secureFieldValues[field.id] ?? "" },
            set: { draft.secureFieldValues[field.id] = $0 }
        )
    }

    private var storedSource: PasswordSource? {
        guard isStored, case .source(let source) = storedPasswordMode else { return nil }
        return source
    }

    private var testContext: ConnectionScriptContext {
        ConnectionScriptContext(
            connectionId: profileId,
            connectionName: "",
            host: "",
            port: 0,
            user: draft.trimmedUsername,
            database: ""
        )
    }

    private var mentionsConnectionDetails: Bool {
        draft.sourceValue.contains("TABLEPRO_") || testContext.substitutingPlaceholders(in: draft.sourceValue) != draft.sourceValue
    }

    // A source typed here is the user's own; one read back unchanged from a profiles file something else wrote is not.
    static func testRefusal(
        for source: PasswordSource,
        storedSource: PasswordSource?,
        storeIsTrusted: Bool
    ) -> PasswordSourceResolver.ResolutionError? {
        guard !storeIsTrusted, let storedSource, source == normalizedLikeTheFields(storedSource) else { return nil }
        return .profileStoreNotTrusted
    }

    // The fields trim what they hold, so the stored value is compared the same way or padding alone would pass for an edit.
    private static func normalizedLikeTheFields(_ source: PasswordSource) -> PasswordSource {
        let (kind, value, field) = PasswordSourceKind.decompose(source)
        let vaultAccess = source.vaultDatabaseRole.map(VaultAccessDraft.init) ?? VaultAccessDraft()
        return kind.source(value: value, field: field, reuseSeconds: nil, vaultAccess: vaultAccess)
    }

    private var bottomBar: some View {
        DialogFooter {
            if isStored {
                Button(String(localized: "Delete Profile"), role: .destructive) {
                    pendingDeletion = PendingProfileDeletion.make(kind: .credential, id: profileId, name: baseline.trimmedName)
                }
                .disabled(usageUnknown)
                .accessibilityIdentifier("credential-profile-delete")
                .profileDeletionAlert($pendingDeletion) { _ in deleteProfile() }
            }
            statusLabel
        } actions: {
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("credential-profile-cancel")
            Button(isStored ? String(localized: "Save") : String(localized: "Create")) { saveProfile() }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.validationIssues.isEmpty)
                .accessibilityIdentifier("credential-profile-save")
        }
        .padding()
    }

    @ViewBuilder private var statusLabel: some View {
        if let saveError {
            NoticeLabel(saveError, severity: .error)
                .lineLimit(2)
        } else if hasLoaded, draft != baseline, let issue = draft.validationIssues.first {
            NoticeLabel(issue)
                .lineLimit(2)
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true

        let profiles = storage.loadProfiles()
        let stored = existingProfile.flatMap { existing in profiles.first { $0.id == existing.id } }
        isStored = stored != nil
        usageUnknown = ConnectionStorage.shared.isLibraryUnreadable
        if let address = ProcessInfo.processInfo.environment["VAULT_ADDR"] {
            vaultAddressPrompt = address
        }

        var loaded = CredentialProfileDraft()
        loaded.takenNames = profiles.filter { $0.id != profileId }.map(\.name)
        let record = stored ?? existingProfile
        if let record {
            loaded.name = record.name
            loaded.username = record.username
            loaded.apply(record.passwordMode)
        }
        storedPasswordMode = stored?.passwordMode

        // A profile not saved yet has no Keychain items; its secrets come from the connection that promoted it.
        if let stored {
            if stored.passwordMode.usesStoredSecret {
                passwordRead = storage.readPassword(for: stored.id)
                loaded.password = passwordRead.value ?? ""
            }
            for fieldId in stored.secureFieldIds {
                let read = storage.readSecureField(fieldId: fieldId, for: stored.id)
                fieldReads[fieldId] = read
                if let value = read.value {
                    loaded.secureFieldValues[fieldId] = value
                }
            }
        } else {
            loaded.password = initialPassword ?? ""
        }
        passwordWasPrefilled = !loaded.password.isEmpty

        loadSecureFieldTypes(holding: Set(record?.secureFieldIds ?? []))
        draft = loaded
        baseline = loaded
    }

    private func loadSecureFieldTypes(holding heldFieldIds: Set<String>) {
        var types: [DatabaseType] = []
        var fieldsByType: [DatabaseType: [ConnectionField]] = [:]
        for type in DatabaseType.allKnownTypes where fieldsByType[type] == nil {
            let fields = PluginManager.shared.additionalConnectionFields(for: type).filter(\.isSecure)
            guard !fields.isEmpty else { continue }
            types.append(type)
            fieldsByType[type] = fields
        }
        secureFieldTypes = types
        secureFieldsByType = fieldsByType
        if let initialDatabaseType, fieldsByType[initialDatabaseType] != nil {
            secureFieldType = initialDatabaseType
        } else if let held = types.first(where: { type in
            fieldsByType[type, default: []].contains { heldFieldIds.contains($0.id) }
        }) {
            secureFieldType = held
        } else if let first = types.first {
            secureFieldType = first
        }
    }

    private func saveProfile() {
        // Read, then modify: the stored record may have changed since this sheet opened.
        let stored = isStored ? storage.profile(for: profileId) : nil
        var record = stored ?? CredentialProfile(id: profileId, name: draft.trimmedName)
        record.name = draft.trimmedName
        record.username = draft.trimmedUsername
        record.passwordMode = draft.passwordMode

        let passwordChange = ProfileSecretChange.decide(
            applies: draft.passwordKind == .stored,
            value: draft.password,
            read: passwordRead
        )
        let heldFieldIds = Set(record.secureFieldIds)
        var fieldChanges: [String: ProfileSecretChange] = [:]
        for fieldId in heldFieldIds.union(draft.secureFieldValues.keys) {
            // A field that arrived after this sheet read the Keychain was never shown, so it is kept unless retyped.
            let read = fieldReads[fieldId] ?? (heldFieldIds.contains(fieldId) ? .unreadable : .absent)
            fieldChanges[fieldId] = .decide(applies: true, value: draft.secureFieldValues[fieldId] ?? "", read: read)
        }
        record.secureFieldIds = fieldChanges
            .filter { fieldId, change in
                if case .write = change { return true }
                return change == .keep && heldFieldIds.contains(fieldId)
            }
            .map(\.key)
            .sorted()

        let persisted = isStored ? storage.updateProfile(record) : storage.addProfile(record)
        // Keychain items are keyed by the profile id, so writing them for a profile that never reached disk strands them.
        guard persisted else {
            saveError = String(localized: "Could not save the profile. Check disk space and permissions, then try again.")
            return
        }
        isStored = true
        storedPasswordMode = record.passwordMode

        var secretsSaved = apply(passwordChange, write: { storage.savePassword($0, for: profileId) }, delete: {
            storage.deletePassword(for: profileId)
        })
        passwordRead = Self.read(after: passwordChange, before: passwordRead, saved: secretsSaved)
        for (fieldId, change) in fieldChanges.sorted(by: { $0.key < $1.key }) {
            let saved = apply(change, write: { storage.saveSecureField($0, fieldId: fieldId, for: profileId) }, delete: {
                storage.deleteSecureField(fieldId: fieldId, for: profileId)
            })
            fieldReads[fieldId] = Self.read(after: change, before: fieldReads[fieldId] ?? .absent, saved: saved)
            secretsSaved = secretsSaved && saved
        }
        guard secretsSaved else {
            saveError = String(localized: "The profile was saved, but its password couldn't be saved to the Keychain.")
            return
        }
        saveError = nil
        onSave?(record)
        dismiss()
    }

    private func apply(_ change: ProfileSecretChange, write: (String) -> Bool, delete: () -> Void) -> Bool {
        switch change {
        case .write(let value):
            return write(value)
        case .keep:
            return true
        case .delete:
            delete()
            return true
        }
    }

    private static func read(after change: ProfileSecretChange, before: ProfileSecretRead, saved: Bool) -> ProfileSecretRead {
        switch change {
        case .write(let value): saved ? .found(value) : before
        case .keep: before
        case .delete: .absent
        }
    }

    private func deleteProfile() {
        guard let stored = storage.profile(for: profileId) else {
            guard storage.lastLoadFailed else {
                onDelete?()
                dismiss()
                return
            }
            saveError = ConnectionCountCopy.deleteFailedMessage
            return
        }
        guard storage.deleteProfile(stored) else {
            saveError = ConnectionCountCopy.deleteFailedMessage
            return
        }
        onDelete?()
        dismiss()
    }

    private static let reusePresets = [300, 900, 3_600, 28_800]

    private static func reuseChoices(including current: Int?) -> [Int] {
        guard let current, !reusePresets.contains(current) else { return reusePresets }
        return (reusePresets + [current]).sorted()
    }
}
