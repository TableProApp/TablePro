import SwiftUI
import TableProSSHConfig
import TableProSSHTransport

struct SSHProfileDraft: Equatable {
    var name = ""
    var server = SSHServerDraft()

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if trimmedName.isEmpty {
            issues.append(String(localized: "A profile needs a name."))
        }
        return issues + server.validationIssues
    }
}

struct SSHProfileEditorView: View {
    private enum TestState: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss

    let existingProfile: SSHProfile?
    var initialPassword: String?
    var initialKeyPassphrase: String?
    var initialTOTPSecret: String?
    var onSave: ((SSHProfile) -> Void)?
    var onDelete: (() -> Void)?

    @State private var draft = SSHProfileDraft()
    @State private var baseline = SSHProfileDraft()
    @State private var hasLoaded = false
    @State private var isStored = false
    @State private var newProfileId = UUID()
    @State private var secretReads: [SSHSecret: ProfileSecretRead] = [:]
    @State private var inheritedSecrets: Set<SSHSecret> = []
    @State private var usageUnknown = false
    @State private var configEntries: [SSHConfigEntry] = []
    @State private var pendingDeletion: PendingProfileDeletion?
    @State private var saveError: String?
    @State private var test = TestState.idle
    @State private var testTask: Task<Void, Never>?

    private var storage: SSHProfileStorage { .shared }

    private var profileId: UUID {
        existingProfile?.id ?? newProfileId
    }

    private var savedSecrets: Set<SSHSecret> {
        Set(secretReads.filter { $0.value != .absent }.map(\.key)).union(inheritedSecrets)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Profile")) {
                    TextField(String(localized: "Name"), text: $draft.name, prompt: Text("My Server"))
                        .accessibilityIdentifier("ssh-profile-name")
                }
                if secretReads.values.contains(.unreadable) {
                    Section {
                        NoticeLabel(
                            String(localized: "The Keychain could not be read, so the stored secrets are not shown. Editing the name is safe; they are left as they are.")
                        )
                    }
                }
                SSHServerFields(
                    draft: $draft.server,
                    configEntries: configEntries,
                    identifierPrefix: "ssh-profile",
                    savedSecrets: savedSecrets
                )
            }
            .formStyle(.grouped)

            Divider()
            bottomBar
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 440, idealHeight: 560)
        .onAppear(perform: load)
        .task {
            configEntries = await Task.detached { SSHConfigParser.parse() }.value
        }
        .onChange(of: draft) { _ in
            cancelTest()
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    private var bottomBar: some View {
        DialogFooter {
            if isStored {
                Button(String(localized: "Delete Profile"), role: .destructive) {
                    pendingDeletion = PendingProfileDeletion.make(kind: .ssh, id: profileId, name: baseline.trimmedName)
                }
                .disabled(usageUnknown)
                .accessibilityIdentifier("ssh-profile-delete")
                .profileDeletionAlert($pendingDeletion) { _ in deleteProfile() }
            }
            statusLabel
        } actions: {
            Button(String(localized: "Test Connection"), action: testConnection)
                .disabled(test == .running || !draft.server.validationIssues.isEmpty)
                .accessibilityIdentifier("ssh-profile-test")
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ssh-profile-cancel")
            Button(isStored ? String(localized: "Save") : String(localized: "Create")) { saveProfile() }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.validationIssues.isEmpty)
                .accessibilityIdentifier("ssh-profile-save")
        }
        .padding()
    }

    @ViewBuilder private var statusLabel: some View {
        if let saveError {
            NoticeLabel(saveError, severity: .error)
                .lineLimit(2)
                .truncationMode(.tail)
        } else {
            switch test {
            case .running:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Testing…")
                        .foregroundStyle(.secondary)
                }
            case .succeeded:
                NoticeLabel(String(localized: "Connected"), severity: .success)
            case .failed(let message):
                NoticeLabel(message, severity: .error)
                    .lineLimit(2)
                    .truncationMode(.tail)
            case .idle:
                if hasLoaded, draft != baseline, let issue = draft.validationIssues.first {
                    NoticeLabel(issue)
                        .lineLimit(2)
                }
            }
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true

        let stored = existingProfile.flatMap { storage.profile(for: $0.id) }
        isStored = stored != nil
        usageUnknown = ConnectionStorage.shared.isLibraryUnreadable

        var loaded = SSHProfileDraft()
        if let record = stored ?? existingProfile {
            loaded.name = record.name
            loaded.server = SSHServerDraft(profile: record)
        }
        // A profile not saved yet has no Keychain items; its secrets come from the connection that promoted it.
        if let stored {
            for secret in SSHSecret.allCases {
                let read = storage.readSecret(secret, for: stored.id)
                secretReads[secret] = read
                loaded.server.setValue(read.value ?? "", of: secret)
            }
        } else {
            loaded.server.password = initialPassword ?? ""
            loaded.server.keyPassphrase = initialKeyPassphrase ?? ""
            loaded.server.totpSecret = initialTOTPSecret ?? ""
            // They came out of the connection's Keychain, so revealing them asks for authentication like a stored secret.
            inheritedSecrets = loaded.server.filledSecrets
        }
        draft = loaded
        baseline = loaded
    }

    private func saveProfile() {
        // Read, then modify: the stored record may have changed since this sheet opened.
        let stored = isStored ? storage.profile(for: profileId) : nil
        var record = stored ?? SSHProfile(id: profileId, name: draft.trimmedName)
        record.name = draft.trimmedName
        draft.server.apply(to: &record)

        let persisted = isStored ? storage.updateProfile(record) : storage.addProfile(record)
        // Keychain items are keyed by the profile id, so writing them for a profile that never reached disk strands them.
        guard persisted else {
            saveError = String(localized: "Could not save the profile. Reopen the SSH settings and try again.")
            return
        }
        isStored = true

        var secretsSaved = true
        for secret in SSHSecret.allCases {
            let before = secretReads[secret] ?? .absent
            switch ProfileSecretChange.decide(
                applies: draft.server.applies(secret),
                value: draft.server.value(of: secret),
                read: before
            ) {
            case .write(let value):
                if storage.saveSecret(value, secret, for: profileId) {
                    secretReads[secret] = .found(value)
                } else {
                    secretsSaved = false
                }
            case .keep:
                break
            case .delete:
                storage.deleteSecret(secret, for: profileId)
                secretReads[secret] = .absent
            }
        }
        guard secretsSaved else {
            saveError = String(localized: "The profile was saved, but its password couldn't be saved to the Keychain.")
            return
        }
        saveError = nil
        onSave?(record)
        dismiss()
    }

    private func testConnection() {
        cancelTest()
        test = .running
        let config = draft.server.configuration()
        let credentials = draft.server.testCredentials
        testTask = Task {
            do {
                try await SSHTunnelManager.shared.testSSHProfile(config: config, credentials: credentials)
                guard !Task.isCancelled else { return }
                test = .succeeded
            } catch {
                guard !Task.isCancelled else { return }
                test = .failed(error.localizedDescription)
            }
        }
    }

    // An edit makes the last result stale, and a test still running answers for values no longer on screen.
    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        test = .idle
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
}
