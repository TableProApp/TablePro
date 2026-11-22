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

    enum SecretKind: CaseIterable, Sendable {
        case password
        case keyPassphrase
        case totpSecret
    }

    enum SaveOutcome: Equatable, Sendable {
        case saved
        case recordNotSaved
        // The record is on disk; these secrets are not.
        case secretsNotSaved([SecretKind])
    }

    private let profilesKey = "com.TablePro.sshProfiles"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychain: any KeychainStoring
    private let connectionStorageProvider: () -> ConnectionStorage
    private let syncTracker: SyncChangeTracker
    private(set) var lastLoadFailed = false

    // The keychain comes from AppStorageEnvironment so a sandboxed run keeps profile secrets in its sandbox.
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

    @discardableResult
    func saveProfiles(_ profiles: [SSHProfile]) -> Bool {
        let previous = loadProfiles()
        guard saveProfilesWithoutSync(profiles) else { return false }
        syncTracker.markDirty(.sshProfile, ids: SyncRecordChanges.changedIds(from: previous, to: profiles))
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
        // Best effort: a connection the fan-out missed is still resolved against the profile at connect time.
        if !refreshLinkedConnections(with: profile) {
            Self.logger.error("Saved SSH profile \(profile.id.uuidString, privacy: .public) but could not update the connections linked to it")
        }
        return true
    }

    // Record first: a secret written under an id that never reached disk is one nothing can name.
    func save(_ profile: SSHProfile, isNew: Bool, secrets: [SecretKind: StoredSecretDraft.Change]) -> SaveOutcome {
        let persisted = isNew ? addProfile(profile) : updateProfile(profile)
        guard persisted else { return .recordNotSaved }

        var failed: [SecretKind] = []
        for kind in SecretKind.allCases {
            switch secrets[kind] ?? .keep {
            case .keep:
                continue
            case .write(let value):
                if !keychain.writeString(value, forKey: Self.key(kind, profile.id)) {
                    failed.append(kind)
                }
            case .delete:
                keychain.delete(forKey: Self.key(kind, profile.id))
            }
        }
        return failed.isEmpty ? .saved : .secretsNotSaved(failed)
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

    // A linked connection tunnels with its stored snapshot, so an edited host has to reach every snapshot.
    @discardableResult
    func refreshLinkedConnections(with profile: SSHProfile, byUser: Bool = true) -> Bool {
        let storage = connectionStorageProvider()
        let linked = Set(
            storage.loadConnections()
                .filter { $0.isLinked(toSSHProfile: profile.id) }
                .map { $0.id }
        )
        return storage.mutateConnections(ids: linked, byUser: byUser) { connection in
            connection = profile.applied(to: connection)
        }
    }

    // Covers a profile synced from another Mac before any fan-out ran here.
    func refreshingLinkedProfile(_ connection: DatabaseConnection) -> DatabaseConnection {
        guard case .profile(let profileId, _) = connection.sshTunnelMode,
              let profile = profile(for: profileId)
        else { return connection }
        return profile.applied(to: connection)
    }

    // Converts from the profile as it stands, never the snapshot: a stale snapshot would send new
    // credentials to the old server. Refuses when the secrets cannot move, since nothing could recover them.
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

        // A connection still on the profile never reads its inline namespace, so the copies go back.
        if !converted {
            for connection in linked {
                storage.deleteSSHPassword(for: connection.id)
                storage.deleteKeyPassphrase(for: connection.id)
                storage.deleteTOTPSecret(for: connection.id)
            }
        }
        return converted
    }

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

    // Nil when any secret could not be read; a profile with none reads as three nils.
    private func readSecrets(for profileId: UUID) -> ProfileSecrets? {
        var values: [SecretKind: String] = [:]
        for kind in SecretKind.allCases {
            switch storedSecret(kind, for: profileId) {
            case .unreadable:
                return nil
            case .absent:
                continue
            case .value(let value):
                values[kind] = value
            }
        }
        return ProfileSecrets(
            password: values[.password],
            keyPassphrase: values[.keyPassphrase],
            totpSecret: values[.totpSecret]
        )
    }

    func storedSecret(_ kind: SecretKind, for profileId: UUID) -> StoredSecretDraft.Stored {
        StoredSecretDraft.Stored(keychain.readStringResult(forKey: Self.key(kind, profileId)))
    }

    // Every item this type writes: a key missing here outlives its owner with nothing left to name it.
    func deleteSecrets(for profileId: UUID) {
        for kind in SecretKind.allCases {
            keychain.delete(forKey: Self.key(kind, profileId))
        }
    }

    // MARK: - SSH Password Storage

    @discardableResult
    func saveSSHPassword(_ password: String, for profileId: UUID) -> Bool {
        keychain.writeString(password, forKey: Self.passwordKey(profileId))
    }

    func loadSSHPassword(for profileId: UUID) -> String? {
        resolveString(label: "SSH profile password", profileId: profileId, forKey: Self.passwordKey(profileId))
    }

    func deleteSSHPassword(for profileId: UUID) {
        keychain.delete(forKey: Self.passwordKey(profileId))
    }

    // MARK: - Key Passphrase Storage

    @discardableResult
    func saveKeyPassphrase(_ passphrase: String, for profileId: UUID) -> Bool {
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

    @discardableResult
    func saveTOTPSecret(_ secret: String, for profileId: UUID) -> Bool {
        keychain.writeString(secret, forKey: Self.totpKey(profileId))
    }

    func loadTOTPSecret(for profileId: UUID) -> String? {
        resolveString(label: "SSH profile TOTP secret", profileId: profileId, forKey: Self.totpKey(profileId))
    }

    func deleteTOTPSecret(for profileId: UUID) {
        keychain.delete(forKey: Self.totpKey(profileId))
    }

    private static func key(_ kind: SecretKind, _ profileId: UUID) -> String {
        switch kind {
        case .password: passwordKey(profileId)
        case .keyPassphrase: passphraseKey(profileId)
        case .totpSecret: totpKey(profileId)
        }
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

// A secret as the Keychain returned it and as the user left it, so a failed read never becomes a delete.
struct StoredSecretDraft: Equatable, Sendable {
    enum Stored: Equatable, Sendable {
        case absent
        case value(String)
        case unreadable

        init(_ result: KeychainStringResult) {
            switch result {
            case .found(let value): self = value.isEmpty ? .absent : .value(value)
            case .notFound: self = .absent
            case .locked, .userCancelled, .authFailed, .error: self = .unreadable
            }
        }
    }

    enum Change: Equatable, Sendable {
        case keep
        case write(String)
        case delete
    }

    let stored: Stored
    var text: String
    var removesUnreadable = false

    init(stored: Stored, fallback: String? = nil) {
        self.stored = stored
        if case .value(let value) = stored {
            text = value
        } else {
            text = fallback ?? ""
        }
    }

    var showsUnreadableNotice: Bool {
        stored == .unreadable && text.isEmpty
    }

    // Whether a Keychain item will exist for this secret after the change runs.
    func keepsItem(inUse: Bool) -> Bool {
        switch change(inUse: inUse) {
        case .write: true
        case .delete: false
        case .keep: stored != .absent
        }
    }

    func change(inUse: Bool) -> Change {
        if inUse, !text.isEmpty {
            return stored == .value(text) ? .keep : .write(text)
        }
        switch stored {
        case .absent: return .keep
        case .value: return .delete
        case .unreadable: return removesUnreadable ? .delete : .keep
        }
    }
}
