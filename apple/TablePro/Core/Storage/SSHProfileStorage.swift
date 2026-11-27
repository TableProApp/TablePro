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
    private let syncJournal: SyncHostJournal
    private(set) var lastLoadFailed = false

    // The Keychain comes from AppStorageEnvironment, so a sandboxed run keeps profile secrets inside the sandbox.
    init(
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        keychain: any KeychainStoring = AppStorageEnvironment.shared.keychain,
        syncJournal: SyncHostJournal = .shared,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared
    ) {
        self.defaults = userDefaults
        self.keychain = keychain
        self.syncJournal = syncJournal
        self.connectionStorageProvider = connectionStorage
    }

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

    // False when nothing reached disk, so a caller that also writes Keychain items or journals a deletion can stop.
    @discardableResult
    func saveProfiles(_ profiles: [SSHProfile]) -> Bool {
        let previous = loadProfiles()
        guard saveProfilesWithoutSync(profiles) else { return false }
        syncJournal.recorded(.sshProfile, written: SyncRecordChanges.changedIds(from: previous, to: profiles))
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
        guard !profiles.contains(where: { $0.id == profile.id }) else {
            Self.logger.error("Refusing to add SSH profile \(profile.id.uuidString, privacy: .public): the id is taken")
            return false
        }
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
        // Best effort: a connection whose snapshot was not rewritten is resolved against the profile at connect time.
        if !refreshLinkedConnections(with: profile, byUser: true) {
            Self.logger.error("Saved SSH profile \(profile.id.uuidString, privacy: .public) but could not update the connections linked to it")
        }
        return true
    }

    @discardableResult
    func deleteProfile(_ profile: SSHProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        // The stored record, not the caller's copy: unlinking writes its configuration into every linked connection.
        let current = profiles.first { $0.id == profile.id } ?? profile
        profiles.removeAll { $0.id == profile.id }
        guard unlinkConnections(fromProfile: current, byUser: true) else { return false }
        guard saveProfiles(profiles) else { return false }
        syncJournal.recorded(.sshProfile, deleted: [profile.id.uuidString])

        deleteSecrets(for: profile.id)
        return true
    }

    func profile(for id: UUID) -> SSHProfile? {
        loadProfiles().first { $0.id == id }
    }

    // A linked connection tunnels through its stored snapshot, so an edited profile has to be written into each one.
    @discardableResult
    func refreshLinkedConnections(with profile: SSHProfile, byUser: Bool) -> Bool {
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

    // Covers a profile edited on another Mac, or a fan-out that could not be written, at the moment it matters.
    func refreshingLinkedProfile(_ connection: DatabaseConnection) -> DatabaseConnection {
        guard case .profile(let profileId, _) = connection.sshTunnelMode,
              let profile = profile(for: profileId)
        else { return connection }
        return profile.applied(to: connection)
    }

    // The tunnel comes from the profile as it stands, never a stale snapshot, or new credentials reach the old server.
    // `byUser` false (a sync pull) never signs connections.json, which may hold a command nobody here approved.
    @discardableResult
    func unlinkConnections(fromProfile profile: SSHProfile, byUser: Bool) -> Bool {
        let storage = connectionStorageProvider()
        // An unreadable library may hold connections that use this profile, and they would be left pointing at nothing.
        guard !storage.isLibraryUnreadable else {
            Self.logger.error("Refusing to unlink from SSH profile \(profile.id.uuidString, privacy: .public): the connections could not be read")
            return false
        }
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

        let converted = storage.mutateConnections(ids: Set(linked.map { $0.id }), byUser: byUser) { connection in
            let current = profile.applied(to: connection)
            guard case .profile(_, let config) = current.sshTunnelMode else { return }
            connection = current
            connection.sshTunnelMode = .inline(config)
            connection.sshConfig = config
            connection.sshProfileId = nil
        }

        // A connection still in profile mode never reads its inline namespace, so the copies go back.
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

    // Nil when any of the three could not be read; agent and keyless profiles read as three nils.
    private func readSecrets(for profileId: UUID) -> ProfileSecrets? {
        var values: [SSHSecret: String] = [:]
        for secret in SSHSecret.allCases {
            switch readSecret(secret, for: profileId) {
            case .found(let value): values[secret] = value
            case .absent: break
            case .unreadable: return nil
            }
        }
        return ProfileSecrets(
            password: values[.password],
            keyPassphrase: values[.keyPassphrase],
            totpSecret: values[.totpSecret]
        )
    }

    // Every Keychain item this type writes. A key missing here outlives its profile with nothing left to name it.
    func deleteSecrets(for profileId: UUID) {
        for secret in SSHSecret.allCases {
            deleteSecret(secret, for: profileId)
        }
    }

    func readSecret(_ secret: SSHSecret, for profileId: UUID) -> ProfileSecretRead {
        ProfileSecretRead(keychain.readStringResult(forKey: Self.key(secret, profileId)))
    }

    @discardableResult
    func saveSecret(_ value: String, _ secret: SSHSecret, for profileId: UUID) -> Bool {
        keychain.writeString(value, forKey: Self.key(secret, profileId))
    }

    func deleteSecret(_ secret: SSHSecret, for profileId: UUID) {
        keychain.delete(forKey: Self.key(secret, profileId))
    }

    @discardableResult
    func saveSSHPassword(_ password: String, for profileId: UUID) -> Bool {
        saveSecret(password, .password, for: profileId)
    }

    func loadSSHPassword(for profileId: UUID) -> String? {
        resolveString(label: "SSH profile password", profileId: profileId, secret: .password)
    }

    func deleteSSHPassword(for profileId: UUID) {
        deleteSecret(.password, for: profileId)
    }

    @discardableResult
    func saveKeyPassphrase(_ passphrase: String, for profileId: UUID) -> Bool {
        saveSecret(passphrase, .keyPassphrase, for: profileId)
    }

    func loadKeyPassphrase(for profileId: UUID) -> String? {
        resolveString(label: "SSH profile key passphrase", profileId: profileId, secret: .keyPassphrase)
    }

    func deleteKeyPassphrase(for profileId: UUID) {
        deleteSecret(.keyPassphrase, for: profileId)
    }

    @discardableResult
    func saveTOTPSecret(_ secret: String, for profileId: UUID) -> Bool {
        saveSecret(secret, .totpSecret, for: profileId)
    }

    func loadTOTPSecret(for profileId: UUID) -> String? {
        resolveString(label: "SSH profile TOTP secret", profileId: profileId, secret: .totpSecret)
    }

    func deleteTOTPSecret(for profileId: UUID) {
        deleteSecret(.totpSecret, for: profileId)
    }

    private static func key(_ secret: SSHSecret, _ profileId: UUID) -> String {
        switch secret {
        case .password: "com.TablePro.sshprofile.password.\(profileId.uuidString)"
        case .keyPassphrase: "com.TablePro.sshprofile.keypassphrase.\(profileId.uuidString)"
        case .totpSecret: "com.TablePro.sshprofile.totpsecret.\(profileId.uuidString)"
        }
    }

    // A connect's read: built here, run off the main actor, since SecItemCopyMatching blocks its thread.
    func secretRead(_ secret: SSHSecret, for profileId: UUID) -> DeferredSecretRead {
        let keychain = keychain
        let key = Self.key(secret, profileId)
        let label = "\(Self.label(secret)) (profileId=\(profileId.uuidString))"
        return DeferredSecretRead(key: key, label: label, logger: Self.logger) {
            keychain.readStringResult(forKey: key)
        }
    }

    private static func label(_ secret: SSHSecret) -> String {
        switch secret {
        case .password: "SSH profile password"
        case .keyPassphrase: "SSH profile key passphrase"
        case .totpSecret: "SSH profile TOTP secret"
        }
    }

    private func resolveString(label: String, profileId: UUID, secret: SSHSecret) -> String? {
        keychain.readStringResult(forKey: Self.key(secret, profileId))
            .value(label: "\(label) (profileId=\(profileId.uuidString))", logger: Self.logger)
    }
}
