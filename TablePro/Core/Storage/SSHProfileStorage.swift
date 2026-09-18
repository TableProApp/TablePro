//
//  SSHProfileStorage.swift
//  TablePro
//

import Foundation
import os
import TableProSyncTransport

extension Notification.Name {
    static let sshProfilesDidChange = Notification.Name("SSHProfilesDidChange")
}

@MainActor
final class SSHProfileStorage {
    static let shared = SSHProfileStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SSHProfileStorage")

    private let profilesKey = "com.TablePro.sshProfiles"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychain: any KeychainStoring
    private let connectionStorageProvider: () -> ConnectionStorage
    private let syncTracker: SyncChangeTracker
    private(set) var lastLoadFailed = false

    /// The keychain arrives through `AppStorageEnvironment` rather than as `KeychainHelper.shared`,
    /// so a sandboxed run keeps its profile secrets inside the sandbox instead of writing them to
    /// the real login keychain, exactly as `ConnectionStorage` already does.
    init(
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        keychain: any KeychainStoring = AppStorageEnvironment.shared.keychain,
        syncTracker: SyncChangeTracker = .shared,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared
    ) {
        self.defaults = userDefaults
        self.keychain = keychain
        self.syncTracker = syncTracker
        self.connectionStorageProvider = connectionStorage
    }

    // MARK: - Profile CRUD

    func loadProfiles() -> [SSHProfile] {
        guard let data = defaults.data(forKey: profilesKey) else {
            lastLoadFailed = false
            return []
        }

        do {
            let profiles = try decoder.decode([SSHProfile].self, from: data)
            lastLoadFailed = false
            return profiles
        } catch {
            Self.logger.error("Failed to load SSH profiles: \(error)")
            lastLoadFailed = true
            return []
        }
    }

    /// Returns `false` when nothing reached disk, so a caller that also writes keychain items or
    /// tombstones can abort instead of stranding them against a profile that was never persisted.
    @discardableResult
    func saveProfiles(_ profiles: [SSHProfile]) -> Bool {
        guard saveProfilesWithoutSync(profiles) else { return false }
        syncTracker.markDirty(.sshProfile, ids: profiles.map { $0.id.uuidString })
        return true
    }

    @discardableResult
    func saveProfilesWithoutSync(_ profiles: [SSHProfile]) -> Bool {
        guard !lastLoadFailed else {
            Self.logger.warning("Refusing to save SSH profiles: previous load failed (would overwrite existing data)")
            return false
        }
        do {
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: profilesKey)
            NotificationCenter.default.post(name: .sshProfilesDidChange, object: nil)
            return true
        } catch {
            Self.logger.error("Failed to save SSH profiles: \(error)")
            return false
        }
    }

    @discardableResult
    func addProfile(_ profile: SSHProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        profiles.append(profile)
        return saveProfiles(profiles)
    }

    @discardableResult
    func updateProfile(_ profile: SSHProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        profiles[index] = profile
        guard saveProfiles(profiles) else { return false }
        /// Best effort, and deliberately not part of the result. The profile is the source of
        /// truth and it is saved; a connection whose snapshot could not be rewritten is still
        /// resolved against the profile by `refreshingLinkedProfile` at connect time.
        if !refreshLinkedConnections(with: profile) {
            Self.logger.error("Saved SSH profile \(profile.id.uuidString, privacy: .public) but could not update the connections linked to it")
        }
        return true
    }

    @discardableResult
    func deleteProfile(_ profile: SSHProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        profiles.removeAll { $0.id == profile.id }
        guard unlinkConnections(fromProfile: profile) else { return false }
        guard saveProfiles(profiles) else { return false }
        syncTracker.markDeleted(.sshProfile, id: profile.id.uuidString)

        deleteSecrets(for: profile.id)
        return true
    }

    func profile(for id: UUID) -> SSHProfile? {
        loadProfiles().first { $0.id == id }
    }

    // MARK: - Linked Connections

    /// Writes an edited profile's configuration into every connection that links to it.
    ///
    /// A linked connection stores `.profile(id:snapshot:)`, and that snapshot is what
    /// `resolvedSSHConfig` hands to the tunnel, the URL formatter, the display strings and the
    /// stage labels. Only the secrets were ever resolved live, so changing a profile's host left
    /// every already-linked connection tunnelling to the old one while sending the new password.
    @discardableResult
    func refreshLinkedConnections(with profile: SSHProfile) -> Bool {
        let storage = connectionStorageProvider()
        let linked = Set(
            storage.loadConnections()
                .filter { $0.isLinked(toSSHProfile: profile.id) }
                .map { $0.id }
        )
        return storage.mutateConnections(ids: linked) { connection in
            connection = profile.applied(to: connection)
        }
    }

    /// The connection as it would be if the fan-out above had already run for it.
    ///
    /// The fan-out covers an edit made here. This covers the window before one has run: a profile
    /// edited on another Mac and synced down, or a connection whose store could not be written.
    /// Connecting is the moment the answer has to be right, so it asks the profile directly.
    func refreshingLinkedProfile(_ connection: DatabaseConnection) -> DatabaseConnection {
        guard case .profile(let profileId, _) = connection.sshTunnelMode,
              let profile = profile(for: profileId)
        else { return connection }
        return profile.applied(to: connection)
    }

    /// Turns every connection pointing at a profile that is going away into an inline tunnel
    /// carrying the same configuration, so a delete never leaves a connection addressing a profile
    /// id that no longer resolves.
    ///
    /// The configuration comes from the profile as it stands now, never from the connection's
    /// stored snapshot: a snapshot the fan-out never reached is stale, and converting that one
    /// while handing over the profile's current password would send new credentials to the old
    /// server. Returns false without changing anything when the secrets cannot be moved, because a
    /// connection converted without them cannot authenticate and there is nothing left to recover
    /// them from once the profile is deleted.
    @discardableResult
    func unlinkConnections(fromProfile profile: SSHProfile) -> Bool {
        let storage = connectionStorageProvider()
        let linked = storage.loadConnections().filter { $0.isLinked(toSSHProfile: profile.id) }
        guard !linked.isEmpty else { return true }

        guard let secrets = readSecrets(for: profile.id) else {
            Self.logger.error("Refusing to unlink from SSH profile \(profile.id.uuidString, privacy: .public): its secrets could not be read")
            return false
        }
        for connection in linked where !secrets.write(into: storage, for: connection.id) {
            Self.logger.error("Refusing to unlink from SSH profile \(profile.id.uuidString, privacy: .public): a secret could not be copied")
            return false
        }

        let converted = storage.mutateConnections(ids: Set(linked.map { $0.id })) { connection in
            let current = profile.applied(to: connection)
            guard case .profile(_, let config) = current.sshTunnelMode else { return }
            connection = current
            connection.sshTunnelMode = .inline(config)
            connection.sshConfig = config
            connection.sshProfileId = nil
        }

        /// The copies go back if the conversion did not land. A connection still in profile mode
        /// reads its secrets from the profile, so the copy would sit in its inline namespace with
        /// nothing reading it. Deleting is safe there because the form already clears that
        /// namespace on every save a profile-linked connection makes.
        if !converted {
            for connection in linked {
                storage.deleteSSHPassword(for: connection.id)
                storage.deleteKeyPassphrase(for: connection.id)
                storage.deleteTOTPSecret(for: connection.id)
            }
        }
        return converted
    }

    /// A profile's secrets on their way into a connection's own keychain namespace, which is where
    /// an inline tunnel reads them from.
    private struct ProfileSecrets {
        let password: String?
        let keyPassphrase: String?
        let totpSecret: String?

        @MainActor
        func write(into storage: ConnectionStorage, for connectionId: UUID) -> Bool {
            if let password, !storage.saveSSHPassword(password, for: connectionId) { return false }
            if let keyPassphrase, !storage.saveKeyPassphrase(keyPassphrase, for: connectionId) { return false }
            if let totpSecret, !storage.saveTOTPSecret(totpSecret, for: connectionId) { return false }
            return true
        }
    }

    private enum SecretRead {
        case readable(String?)
        case unreadable
    }

    /// Nil when any of the three could not be read. A profile that simply has none reads as three
    /// nils, which is correct for agent and keyless authentication.
    private func readSecrets(for profileId: UUID) -> ProfileSecrets? {
        guard case .readable(let password) = readSecret(Self.passwordKey(profileId)),
              case .readable(let keyPassphrase) = readSecret(Self.passphraseKey(profileId)),
              case .readable(let totpSecret) = readSecret(Self.totpKey(profileId))
        else { return nil }
        return ProfileSecrets(password: password, keyPassphrase: keyPassphrase, totpSecret: totpSecret)
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

    /// Every keychain item this type writes, removed together. A key written here and missing from
    /// this list is a secret that outlives its owner with nothing left that can name it.
    func deleteSecrets(for profileId: UUID) {
        deleteSSHPassword(for: profileId)
        deleteKeyPassphrase(for: profileId)
        deleteTOTPSecret(for: profileId)
    }

    // MARK: - SSH Password Storage

    func saveSSHPassword(_ password: String, for profileId: UUID) {
        keychain.writeString(password, forKey: Self.passwordKey(profileId))
    }

    func loadSSHPassword(for profileId: UUID) -> String? {
        resolveString(label: "SSH profile password", profileId: profileId, forKey: Self.passwordKey(profileId))
    }

    func deleteSSHPassword(for profileId: UUID) {
        keychain.delete(forKey: Self.passwordKey(profileId))
    }

    // MARK: - Key Passphrase Storage

    func saveKeyPassphrase(_ passphrase: String, for profileId: UUID) {
        keychain.writeString(passphrase, forKey: Self.passphraseKey(profileId))
    }

    func loadKeyPassphrase(for profileId: UUID) -> String? {
        resolveString(
            label: "SSH profile key passphrase",
            profileId: profileId,
            forKey: Self.passphraseKey(profileId)
        )
    }

    func deleteKeyPassphrase(for profileId: UUID) {
        keychain.delete(forKey: Self.passphraseKey(profileId))
    }

    // MARK: - TOTP Secret Storage

    func saveTOTPSecret(_ secret: String, for profileId: UUID) {
        keychain.writeString(secret, forKey: Self.totpKey(profileId))
    }

    func loadTOTPSecret(for profileId: UUID) -> String? {
        resolveString(label: "SSH profile TOTP secret", profileId: profileId, forKey: Self.totpKey(profileId))
    }

    func deleteTOTPSecret(for profileId: UUID) {
        keychain.delete(forKey: Self.totpKey(profileId))
    }

    private static func passwordKey(_ profileId: UUID) -> String {
        "com.TablePro.sshprofile.password.\(profileId.uuidString)"
    }

    private static func passphraseKey(_ profileId: UUID) -> String {
        "com.TablePro.sshprofile.keypassphrase.\(profileId.uuidString)"
    }

    private static func totpKey(_ profileId: UUID) -> String {
        "com.TablePro.sshprofile.totpsecret.\(profileId.uuidString)"
    }

    private func resolveString(label: String, profileId: UUID, forKey key: String) -> String? {
        keychain.readStringResult(forKey: key)
            .value(label: "\(label) (profileId=\(profileId.uuidString))", logger: Self.logger)
    }
}
