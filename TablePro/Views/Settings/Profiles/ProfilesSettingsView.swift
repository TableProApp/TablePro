//
//  ProfilesSettingsView.swift
//  TablePro
//

import SwiftUI

/// The profiles a connection can point at, in one place.
///
/// Both kinds used to be reachable only from inside a connection form's Network tab, through three
/// small buttons, with no list of them anywhere and no way to see which connections used one.
struct ProfilesSettingsView: View {
    @State private var credentialProfiles: [CredentialProfile] = []
    @State private var sshProfiles: [SSHProfile] = []

    @State private var editingCredentialProfile: CredentialProfile?
    @State private var isAddingCredentialProfile = false
    @State private var editingSSHProfile: SSHProfile?
    @State private var isAddingSSHProfile = false

    @State private var connectionCounts: [UUID: Int] = [:]

    var body: some View {
        Form {
            credentialSection
            sshSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear(perform: reload)
        /// The Settings window is kept alive between openings, so a profile created from a
        /// connection window has to reach this list while it is already on screen.
        .onReceive(NotificationCenter.default.publisher(for: .credentialProfilesDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sshProfilesDidChange)) { _ in reload() }
        .sheet(item: $editingCredentialProfile) { profile in
            CredentialProfileEditorSheet(
                existingProfile: profile,
                onSave: { _ in reload() },
                onDelete: { reload() }
            )
        }
        .sheet(isPresented: $isAddingCredentialProfile) {
            CredentialProfileEditorSheet(existingProfile: nil, onSave: { _ in reload() })
        }
        .sheet(item: $editingSSHProfile) { profile in
            SSHProfileEditorView(
                existingProfile: profile,
                onSave: { _ in reload() },
                onDelete: { reload() }
            )
        }
        .sheet(isPresented: $isAddingSSHProfile) {
            SSHProfileEditorView(existingProfile: nil, onSave: { _ in reload() })
        }
    }

    // MARK: - Credential profiles

    private var credentialSection: some View {
        Section {
            if credentialProfiles.isEmpty {
                emptyRow(String(localized: "No credential profiles yet."))
            } else {
                ForEach(credentialProfiles) { profile in
                    row(
                        title: profile.name,
                        detail: profile.summary,
                        symbol: "key.fill",
                        usedBy: connectionCounts[profile.id] ?? 0,
                        identifier: "credential-profile-row-\(profile.id.uuidString)"
                    ) {
                        editingCredentialProfile = profile
                    }
                    .contextMenu {
                        Button(String(localized: "Edit…")) { editingCredentialProfile = profile }
                        Button(String(localized: "Duplicate")) { duplicate(profile) }
                    }
                }
            }
            Button {
                isAddingCredentialProfile = true
            } label: {
                Label(String(localized: "Add Credential Profile…"), systemImage: "plus")
            }
            .accessibilityIdentifier("add-credential-profile")
        } header: {
            Text(String(localized: "Credential Profiles"))
        } footer: {
            Text("One username and password, shared by any number of connections. Change it here and every connection using it signs in with the new one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - SSH profiles

    private var sshSection: some View {
        Section {
            if sshProfiles.isEmpty {
                emptyRow(String(localized: "No SSH servers yet."))
            } else {
                ForEach(sshProfiles) { profile in
                    row(
                        title: profile.name,
                        detail: sshDetail(profile),
                        symbol: "network",
                        usedBy: connectionCounts[profile.id] ?? 0,
                        identifier: "ssh-profile-row-\(profile.id.uuidString)"
                    ) {
                        editingSSHProfile = profile
                    }
                    .contextMenu {
                        Button(String(localized: "Edit…")) { editingSSHProfile = profile }
                    }
                }
            }
            Button {
                isAddingSSHProfile = true
            } label: {
                Label(String(localized: "Add SSH Server…"), systemImage: "plus")
            }
            .accessibilityIdentifier("add-ssh-profile")
        } header: {
            Text(String(localized: "SSH Servers"))
        } footer: {
            Text("One bastion, many connections. Editing the server or its credentials reaches every connection tunnelling through it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sshDetail(_ profile: SSHProfile) -> String {
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return profile.host }
        return "\(user)@\(profile.host)"
    }

    // MARK: - Rows

    private func row(
        title: String,
        detail: String,
        symbol: String,
        usedBy: Int,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(usedByLabel(usedBy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title), \(detail), \(usedByLabel(usedBy))")
    }

    private func usedByLabel(_ count: Int) -> String {
        guard count > 0 else { return String(localized: "Unused") }
        return String(format: String(localized: "Used by %lld"), Int64(count))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
    }

    // MARK: - Data

    private func reload() {
        credentialProfiles = CredentialProfileStorage.shared.loadProfiles()
        sshProfiles = SSHProfileStorage.shared.loadProfiles()

        var counts: [UUID: Int] = [:]
        for connection in ConnectionStorage.shared.loadConnections() {
            if let id = connection.credentialMode.profileId {
                counts[id, default: 0] += 1
            }
            if case .profile(let id, _) = connection.sshTunnelMode {
                counts[id, default: 0] += 1
            }
        }
        connectionCounts = counts
    }

    /// The editor refuses two profiles with one name, so duplicating twice must not create them
    /// either: every picker offers a profile by its name alone.
    private func availableName(basedOn name: String) -> String {
        let taken = Set(credentialProfiles.map { $0.name.lowercased() })
        let first = String(format: String(localized: "%@ (Copy)"), name)
        guard taken.contains(first.lowercased()) else { return first }
        for index in 2...99 {
            let candidate = String(format: String(localized: "%1$@ (Copy %2$lld)"), name, Int64(index))
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return first
    }

    private func duplicate(_ profile: CredentialProfile) {
        let copy = CredentialProfile(
            name: availableName(basedOn: profile.name),
            username: profile.username,
            passwordMode: profile.passwordMode,
            secureFieldIds: profile.secureFieldIds
        )
        guard CredentialProfileStorage.shared.addProfile(copy) else { return }
        if case .stored = profile.passwordMode,
           let password = CredentialProfileStorage.shared.loadPassword(for: profile.id) {
            CredentialProfileStorage.shared.savePassword(password, for: copy.id)
        }
        for fieldId in profile.secureFieldIds {
            if let value = CredentialProfileStorage.shared.loadSecureField(fieldId: fieldId, for: profile.id) {
                CredentialProfileStorage.shared.saveSecureField(value, fieldId: fieldId, for: copy.id)
            }
        }
        reload()
    }
}
