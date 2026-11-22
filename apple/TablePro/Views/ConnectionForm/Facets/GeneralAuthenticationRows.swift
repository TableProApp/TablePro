//
//  GeneralAuthenticationRows.swift
//  TablePro
//

import Network
import SwiftUI
import TableProPluginKit

// The pop-up carries the profile commands as its last items, as a Team or printer pop-up does, so the row keeps
// one control and no button lands on a line of its own.
struct GeneralCredentialsRows: View {
    @ObservedObject var store: ConnectionEditorStore

    @State private var pickerGeneration = 0

    private enum Choice: Hashable {
        case mode(CredentialMode)
        case saveAsProfile
        case manageProfiles
    }

    private var row: EditorRow { .builtIn(.credentialProfile) }

    var body: some View {
        if store.credentialProfileIsMissing {
            LabeledContent {
                HStack(spacing: 8) {
                    picker
                        .labelsHidden()
                        .fixedSize()
                    Button(String(localized: "Enter Credentials Here")) {
                        store.switchToInlineCredentials()
                    }
                    .accessibilityIdentifier("credential-profile-relink")
                }
            } label: {
                EditorRowLabel(String(localized: "Credentials"), row: row, store: store)
            }
            .editorRowFocus(row, store: store)
        } else {
            picker
                .editorRowFocus(row, store: store)
        }

        if let profile = store.selectedCredentialProfile {
            LabeledContent(String(localized: "Username"), value: Self.displayUsername(profile))
            LabeledContent(String(localized: "Password"), value: profile.passwordMode.displayName)
            if case .source(let source) = profile.passwordMode {
                PasswordSourceTestView(
                    source: source,
                    context: { store.passwordSourceContext() },
                    leaseOwner: { profile.id },
                    refusal: {
                        store.services.credentialProfileStorage.storeIsTrusted
                            ? nil : PasswordSourceResolver.ResolutionError.profileStoreNotTrusted
                    }
                )
            }
        }
    }

    private var picker: some View {
        Picker(selection: choice) {
            Text(String(localized: "Enter Below")).tag(Choice.mode(.inline))
            if !store.context.credentialProfiles.isEmpty {
                Divider()
                ForEach(store.context.credentialProfiles) { profile in
                    Text(verbatim: profile.name).tag(Choice.mode(.profile(id: profile.id)))
                }
            }
            // A selection with no matching item reads as nothing chosen, so a profile this Mac lacks gets one.
            if store.credentialProfileIsMissing {
                Text(String(localized: "Missing Profile")).tag(Choice.mode(store.draft.credentials.mode))
            }
            Divider()
            if canSaveAsProfile {
                Text(String(localized: "Save These as a Profile…")).tag(Choice.saveAsProfile)
            }
            Text(String(localized: "Manage Profiles…")).tag(Choice.manageProfiles)
        } label: {
            EditorRowLabel(String(localized: "Credentials"), row: row, store: store)
        }
        .id(pickerGeneration)
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private var canSaveAsProfile: Bool {
        !store.draft.credentials.usesProfile && store.hasPromotableCredentials
    }

    // A command item leaves the selection where it was; the new identity redraws the pop-up on it.
    private var choice: Binding<Choice> {
        Binding(
            get: { .mode(store.draft.credentials.mode) },
            set: { newValue in
                switch newValue {
                case .mode(let mode):
                    store.noteEdited(row)
                    store.setCredentialMode(mode)
                case .saveAsProfile:
                    pickerGeneration += 1
                    store.isSavingCredentialsAsProfile = true
                case .manageProfiles:
                    pickerGeneration += 1
                    WindowOpener.shared.openSettings(tab: .profiles)
                }
            }
        )
    }

    private static func displayUsername(_ profile: CredentialProfile) -> String {
        let trimmed = profile.username.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "None") : trimmed
    }
}

@MainActor
private func passwordTitle(_ store: ConnectionEditorStore) -> String {
    store.traits.connectionMode == .apiOnly ? String(localized: "API Token") : String(localized: "Password")
}

// The password and where it is kept share one row, so "Password" labels it once.
struct GeneralPasswordRow: View {
    @ObservedObject var store: ConnectionEditorStore

    @StateObject private var reveal = SecretReveal()
    @FocusState private var isFocused: Bool

    private var requiresAuthentication: Bool {
        store.draft.credentials.storedPasswordState != .absent
    }

    var body: some View {
        let title = passwordTitle(store)
        LabeledContent {
            HStack(spacing: 8) {
                field(title: title)
                    .labelsHidden()
                    .focused($isFocused)
                    .accessibilityIdentifier(BuiltInRow.password.accessibilityIdentifier)

                Button {
                    Task { await reveal.setRevealed(!reveal.isRevealed, requiresAuthentication: requiresAuthentication) }
                } label: {
                    Image(systemName: reveal.isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealTitle)
                .accessibilityLabel(revealTitle)
                .accessibilityIdentifier("connection-form-password-reveal")

                GeneralPasswordStoragePicker(store: store, title: title)
                    .labelsHidden()
                    .fixedSize()
            }
        } label: {
            EditorRowLabel(title, row: .builtIn(.password), store: store)
        }
        .editorRowFocus(.builtIn(.password), .builtIn(.passwordMode), store: store, isFocused: $isFocused)
    }

    private var revealTitle: String {
        reveal.isRevealed ? String(localized: "Hide password") : String(localized: "Show password")
    }

    @ViewBuilder
    private func field(title: String) -> some View {
        let prompt = Text(verbatim: EditorFieldPrompt.text(nil, row: .builtIn(.password), store: store))
        if reveal.isRevealed {
            TextField(text: password, prompt: prompt) { Text(verbatim: title) }
                .autocorrectionDisabled()
        } else {
            SecureField(text: password, prompt: prompt) { Text(verbatim: title) }
        }
    }

    private var password: Binding<String> {
        Binding(
            get: { store.draft.credentials.password },
            set: { newValue in
                store.noteEdited(.builtIn(.password))
                store.update { $0.credentials.password = newValue }
            }
        )
    }
}

// Without a password field (Ask Every Time, or a source set in connections.json) the choice is the row.
struct GeneralPasswordModeRow: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        if store.draft.credentials.passwordSource != nil {
            Toggle(isOn: store.tracking(store.passwordPromptBinding, row: .builtIn(.passwordMode))) {
                EditorRowLabel(
                    store.traits.connectionMode == .apiOnly
                        ? String(localized: "Prompt for API Token")
                        : String(localized: "Prompt for Password"),
                    row: .builtIn(.passwordMode),
                    store: store
                )
            }
            .accessibilityIdentifier(BuiltInRow.passwordMode.accessibilityIdentifier)
            .editorRowFocus(.builtIn(.passwordMode), store: store)
        } else {
            GeneralPasswordStoragePicker(store: store, title: passwordTitle(store))
                .editorRowFocus(.builtIn(.passwordMode), store: store)
        }
    }
}

struct GeneralPasswordStoragePicker: View {
    @ObservedObject var store: ConnectionEditorStore
    let title: String

    var body: some View {
        Picker(selection: store.tracking(store.passwordPromptBinding, row: .builtIn(.passwordMode))) {
            Text(String(localized: "Store in Keychain")).tag(false)
            Text(String(localized: "Ask Every Time")).tag(true)
        } label: {
            EditorRowLabel(title, row: .builtIn(.passwordMode), store: store)
        }
        .accessibilityIdentifier(BuiltInRow.passwordMode.accessibilityIdentifier)
    }
}

struct GeneralPasswordSourceRows: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        if let source = store.draft.credentials.passwordSource {
            PasswordSourceSummary(title: passwordTitle(store), source: source)
            PasswordSourceTestView(
                source: source,
                context: { store.passwordSourceContext() },
                leaseOwner: { store.isNew ? nil : store.connectionId },
                refusal: {
                    store.storage.storeIsTrusted ? nil : PasswordSourceResolver.ResolutionError.storeNotTrusted
                }
            )
        }
    }
}

struct GeneralKerberosNote: View {
    @ObservedObject var store: ConnectionEditorStore

    private var usesWindowsAuthentication: Bool {
        ConnectionEditorEngine.usesWindowsAuthentication(store.draft, store.traits)
    }

    private var hostIsIPAddress: Bool {
        let host = ConnectionEditorEngine.resolvedHost(store.draft, store.traits).trimmingCharacters(in: .whitespaces)
        return IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    var body: some View {
        NoticeLabel(
            String(localized: "Leave the principal and password blank to use your existing Kerberos ticket. Run kinit user@REALM.COM in Terminal first if you don't have one."),
            severity: .info
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(BuiltInRow.kerberosNote.accessibilityIdentifier)
        // MariaDB's server names its own principal, so only these two take it from the host.
        if hostIsIPAddress, usesWindowsAuthentication || store.traits.pluginTypeId == "PostgreSQL" {
            NoticeLabel(hostWarning)
        }
    }

    private var hostWarning: String {
        if usesWindowsAuthentication {
            return String(localized: "Windows Authentication needs the server's hostname, not an IP address. Kerberos service principals aren't registered against IP addresses.")
        }
        return String(localized: "Kerberos needs the server's hostname, not an IP address. Service principals aren't registered against IP addresses.")
    }
}

struct GeneralPgpassStatus: View {
    let status: PgpassStatus

    var body: some View {
        if let notice {
            NoticeLabel(notice.text, severity: notice.severity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(BuiltInRow.pgpassStatus.accessibilityIdentifier)
        }
    }

    private var notice: (text: String, severity: NoticeSeverity)? {
        switch status {
        case .notChecked:
            return nil
        case .fileNotFound:
            return (String(localized: "~/.pgpass not found"), .warning)
        case .badPermissions:
            return (String(localized: "~/.pgpass has incorrect permissions (needs chmod 0600)"), .warning)
        case .matchFound:
            return (String(localized: "~/.pgpass found, matching entry exists"), .success)
        case .noMatch:
            return (String(localized: "~/.pgpass found, no matching entry"), .warning)
        }
    }
}
