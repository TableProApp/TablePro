//
//  CredentialProfileStorage.swift
//  TablePro
//

import Foundation
import os
import TableProSyncTransport

extension Notification.Name {
    static let credentialProfilesDidChange = Notification.Name("CredentialProfilesDidChange")
}

/// The named credential profiles, in a file beside `connections.json` and stamped the same way.
///
/// Not `UserDefaults`, which is where SSH profiles live. A credential profile can declare a
/// `PasswordSource.command(shell:)`, and the trust tag is the only thing standing between an
/// attacker-writable file and a command this Mac never agreed to run. `ConnectionStorage` has that
/// tag; the defaults domain has nothing of the kind.
@MainActor
final class CredentialProfileStorage {
    static let shared = CredentialProfileStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CredentialProfileStorage")

    /// The prefix is load-bearing. `TableProMobile`'s `KeychainSecureStore.cleanOrphanedCredentials`
    /// sweeps `com.TablePro.password.` and deletes any item whose trailing UUID is not a saved
    /// connection, and a profile id is never a connection id.
    private static let secretPrefix = "com.TablePro.credprofile."

    private let file: IntegrityStampedFileStore<CredentialProfile>
    private let keychain: any KeychainStoring
    private let syncTracker: SyncChangeTracker
    private let connectionStorageProvider: () -> ConnectionStorage

    /// True when the file exists and would not decode. Saving then would write an empty list over
    /// whatever it holds, so every mutation refuses until a load succeeds.
    private(set) var lastLoadFailed = false

    /// Whether the profiles file is the one TablePro last wrote. `resolvePassword` reads it before
    /// running a profile's password source, exactly as it reads `ConnectionStorage.storeIsTrusted`
    /// before running a connection's.
    var storeIsTrusted: Bool { file.isTrusted }

    init(
        fileURL: URL = CredentialProfileStorage.defaultFileURL(),
        keychain: any KeychainStoring = AppStorageEnvironment.shared.keychain,
        syncTracker: SyncChangeTracker = .shared,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared,
        integrity: ConnectionStoreIntegrity = .shared
    ) {
        self.file = IntegrityStampedFileStore(
            fileURL: fileURL,
            label: "credentialProfiles.json",
            logger: Self.logger,
            userSaveEstablishesTrust: false,
            integrity: integrity
        )
        self.keychain = keychain
        self.syncTracker = syncTracker
        self.connectionStorageProvider = connectionStorage
    }

    nonisolated static func defaultFileURL() -> URL {
        let directory = AppStorageEnvironment.shared.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("credentialProfiles.json")
    }

    // MARK: - Profile CRUD

    func loadProfiles() -> [CredentialProfile] {
        guard let profiles = file.load() else {
            lastLoadFailed = true
            return []
        }
        lastLoadFailed = false
        return profiles.sorted { $0.sortOrder < $1.sortOrder }
    }

    func profile(for id: UUID) -> CredentialProfile? {
        loadProfiles().first { $0.id == id }
    }

    func connectionsUsing(_ profileId: UUID) -> [DatabaseConnection] {
        connectionStorageProvider().loadConnections().filter { $0.credentialMode == .profile(id: profileId) }
    }

    @discardableResult
    func saveProfiles(_ profiles: [CredentialProfile]) -> Bool {
        let previous = loadProfiles()
        guard saveProfilesWithoutSync(profiles) else { return false }
        syncTracker.markDirty(.credentialProfile, ids: SyncRecordChanges.changedIds(from: previous, to: profiles))
        return true
    }

    @discardableResult
    func saveProfilesWithoutSync(_ profiles: [CredentialProfile]) -> Bool {
        guard !lastLoadFailed else {
            Self.logger.warning("Refusing to save credential profiles: the last load failed and this would overwrite them")
            return false
        }
        guard file.save(profiles) else { return false }
        /// The Settings window is kept alive between openings, so a profile created from a
        /// connection window has to reach a Profiles pane that is already on screen.
        NotificationCenter.default.post(name: .credentialProfilesDidChange, object: nil)
        return true
    }

    @discardableResult
    func addProfile(_ profile: CredentialProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        var placed = profile
        placed.sortOrder = (profiles.map { $0.sortOrder }.max() ?? -1) + 1
        profiles.append(placed)
        return saveProfiles(profiles)
    }

    @discardableResult
    func updateProfile(_ profile: CredentialProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        profiles[index] = profile
        guard saveProfiles(profiles) else { return false }
        /// Best effort, and deliberately not part of the result. The profile is saved and the
        /// connect path resolves the username from it either way; this is what keeps the copy on
        /// each connection, which every other reader of `username` uses, in step.
        if !writeUsernameThrough(profile) {
            Self.logger.error(
                "Saved credential profile \(profile.id.uuidString, privacy: .public) but could not update the connections linked to it"
            )
        }
        return true
    }

    /// Deleting hands each linked connection the profile's username and its stored password, as
    /// that connection's own inline credentials, so nothing stops connecting. Returns false without
    /// deleting anything when that hand-over cannot be completed.
    @discardableResult
    func deleteProfile(_ profile: CredentialProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        profiles.removeAll { $0.id == profile.id }
        guard unlinkConnections(from: profile) else { return false }
        guard saveProfiles(profiles) else { return false }
        syncTracker.markDeleted(.credentialProfile, id: profile.id.uuidString)

        deleteSecrets(for: profile)
        return true
    }

    // MARK: - Linked Connections

    /// Copies the profile's username onto every connection that links to it.
    ///
    /// `connection.username` stays populated for a linked connection on purpose. It is read raw by
    /// the AWS IAM signer, the `~/.pgpass` lookup, `NativeDumpRegistry`'s `-U` flags,
    /// `ExternalConnectionTrustKey` and the connection record pushed to iCloud, and blanking it
    /// would have pushed an empty username over the good value on a second Mac.
    @discardableResult
    func writeUsernameThrough(_ profile: CredentialProfile) -> Bool {
        let storage = connectionStorageProvider()
        let linked = Set(
            storage.loadConnections()
                .filter { $0.credentialMode == .profile(id: profile.id) }
                .map { $0.id }
        )
        return storage.mutateConnections(ids: linked) { connection in
            connection.username = profile.username
        }
    }

    @discardableResult
    func unlinkConnections(from profile: CredentialProfile) -> Bool {
        let storage = connectionStorageProvider()
        let linked = storage.loadConnections().filter { $0.credentialMode == .profile(id: profile.id) }
        guard !linked.isEmpty else { return true }

        guard let secrets = readSecrets(for: profile) else {
            Self.logger.error(
                "Refusing to unlink from credential profile \(profile.id.uuidString, privacy: .public): its secrets could not be read"
            )
            return false
        }
        for connection in linked where !secrets.write(into: storage, for: connection.id) {
            Self.logger.error(
                "Refusing to unlink from credential profile \(profile.id.uuidString, privacy: .public): a secret could not be copied"
            )
            return false
        }

        let carriesSource = storeIsTrusted
        let converted = storage.mutateConnections(ids: Set(linked.map { $0.id })) { connection in
            connection.credentialMode = .inline
            connection.username = profile.username
            /// Every inline password field is written, not only the one this profile used. A
            /// connection that carried a prompt flag or a pgpass flag from before it was linked
            /// would otherwise keep it and override the password just copied in.
            connection.promptForPassword = profile.passwordMode == .prompt
            connection.usePgpass = profile.passwordMode == .pgpass
            /// A password source can name a shell command, and `connections.json` re-stamps itself
            /// as trusted whenever the user saves it. Carrying one out of a profiles file that
            /// something else wrote would move a command from a store that refuses to run it into
            /// one that will, with a profile delete standing in for the user's consent. So it is
            /// carried only from a file TablePro itself last wrote; otherwise the connection asks.
            if case .source(let source) = profile.passwordMode, carriesSource {
                connection.passwordSource = source
            } else {
                connection.passwordSource = nil
                if case .source = profile.passwordMode {
                    connection.promptForPassword = true
                }
            }
        }
        if !converted {
            for connection in linked {
                secrets.remove(from: storage, for: connection.id)
            }
        }
        return converted
    }

    // MARK: - Secrets

    func savePassword(_ password: String, for profileId: UUID) -> Bool {
        keychain.writeString(password, forKey: Self.passwordKey(profileId))
    }

    func loadPassword(for profileId: UUID) -> String? {
        keychain.readStringResult(forKey: Self.passwordKey(profileId))
            .value(label: "Credential profile password (profileId=\(profileId.uuidString))", logger: Self.logger)
    }

    func deletePassword(for profileId: UUID) {
        keychain.delete(forKey: Self.passwordKey(profileId))
    }

    @discardableResult
    func saveSecureField(_ value: String, fieldId: String, for profileId: UUID) -> Bool {
        keychain.writeString(value, forKey: Self.fieldKey(fieldId, profileId))
    }

    func loadSecureField(fieldId: String, for profileId: UUID) -> String? {
        keychain.readStringResult(forKey: Self.fieldKey(fieldId, profileId))
            .value(
                label: "Credential profile field \(fieldId) (profileId=\(profileId.uuidString))",
                logger: Self.logger
            )
    }

    func deleteSecureField(fieldId: String, for profileId: UUID) {
        keychain.delete(forKey: Self.fieldKey(fieldId, profileId))
    }

    /// Every keychain item this type writes, removed together. A key written here and missing from
    /// this list is a secret that outlives its owner with nothing left that can name it.
    func deleteSecrets(for profile: CredentialProfile) {
        deletePassword(for: profile.id)
        for fieldId in profile.secureFieldIds {
            deleteSecureField(fieldId: fieldId, for: profile.id)
        }
    }

    private static func passwordKey(_ profileId: UUID) -> String {
        "\(secretPrefix)password.\(profileId.uuidString)"
    }

    private static func fieldKey(_ fieldId: String, _ profileId: UUID) -> String {
        "\(secretPrefix)field.\(fieldId).\(profileId.uuidString)"
    }

    private struct ProfileSecrets {
        let password: String?
        let fields: [String: String]

        @MainActor
        func write(into storage: ConnectionStorage, for connectionId: UUID) -> Bool {
            if let password, !storage.savePassword(password, for: connectionId) { return false }
            for (fieldId, value) in fields
            where !storage.savePluginSecureField(value, fieldId: fieldId, for: connectionId) {
                return false
            }
            return true
        }

        @MainActor
        func remove(from storage: ConnectionStorage, for connectionId: UUID) {
            if password != nil {
                storage.deletePassword(for: connectionId)
            }
            for fieldId in fields.keys {
                storage.deletePluginSecureField(fieldId: fieldId, for: connectionId)
            }
        }
    }

    private enum SecretRead {
        case readable(String?)
        case unreadable
    }

    /// Nil when anything the profile owns exists but could not be read. A profile with no stored
    /// secret reads as an empty set, which is correct for prompt, pgpass and source modes.
    private func readSecrets(for profile: CredentialProfile) -> ProfileSecrets? {
        var password: String?
        if profile.passwordMode.usesStoredSecret {
            guard case .readable(let value) = readSecret(Self.passwordKey(profile.id)) else { return nil }
            password = value
        }
        var fields: [String: String] = [:]
        for fieldId in profile.secureFieldIds {
            guard case .readable(let value) = readSecret(Self.fieldKey(fieldId, profile.id)) else { return nil }
            if let value { fields[fieldId] = value }
        }
        return ProfileSecrets(password: password, fields: fields)
    }

    private func readSecret(_ key: String) -> SecretRead {
        switch keychain.readStringResult(forKey: key) {
        case .found(let value):
            return .readable(value.isEmpty ? nil : value)
        case .notFound:
            return .readable(nil)
        case .locked, .userCancelled, .authFailed, .error:
            return .unreadable
        }
    }
}
