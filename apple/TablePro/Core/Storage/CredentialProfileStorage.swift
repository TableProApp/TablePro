import Foundation
import os
import TableProImport
import TableProSyncTransport

extension Notification.Name {
    static let credentialProfilesDidChange = Notification.Name("CredentialProfilesDidChange")
}

enum ProfileSecretRead: Equatable, Sendable {
    case found(String)
    case absent
    case unreadable

    init(_ result: KeychainStringResult) {
        switch result {
        case .found(let value):
            self = value.isEmpty ? .absent : .found(value)
        case .notFound:
            self = .absent
        case .locked, .userCancelled, .authFailed, .error:
            self = .unreadable
        }
    }

    var value: String? {
        guard case .found(let value) = self else { return nil }
        return value
    }
}

enum ProfileSecretChange: Equatable, Sendable {
    case write(String)
    case keep
    case delete

    // An empty field over a secret that could not be read means "not shown", never "cleared".
    static func decide(applies: Bool, value: String, read: ProfileSecretRead) -> ProfileSecretChange {
        if applies, !value.isEmpty {
            return read == .found(value) ? .keep : .write(value)
        }
        return read == .unreadable ? .keep : .delete
    }
}

// A file and not UserDefaults: a profile can name a shell command, and only the file's trust tag stops one this Mac never agreed to run.
@MainActor
final class CredentialProfileStorage {
    static let shared = CredentialProfileStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CredentialProfileStorage")

    // TableProMobile sweeps `com.TablePro.password.` items whose UUID is not a connection, so profile secrets must not share that prefix.
    nonisolated static let secretKeyPrefix = "com.TablePro.credprofile."
    private static let secretPrefix = secretKeyPrefix

    private let file: IntegrityStampedFileStore<CredentialProfile>
    private let keychain: any KeychainStoring
    private let syncJournal: SyncHostJournal
    private let connectionStorageProvider: () -> ConnectionStorage

    // Every mutation refuses while this is true, or a save would write an empty list over the file.
    private(set) var lastLoadFailed = false

    var storeIsTrusted: Bool { file.isTrusted }

    init(
        fileURL: URL = CredentialProfileStorage.defaultFileURL(),
        keychain: any KeychainStoring = AppStorageEnvironment.shared.keychain,
        syncJournal: SyncHostJournal = .shared,
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
        self.syncJournal = syncJournal
        self.connectionStorageProvider = connectionStorage
    }

    nonisolated static func defaultFileURL() -> URL {
        let directory = AppStorageEnvironment.shared.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("credentialProfiles.json")
    }

    func loadProfiles() -> [CredentialProfile] {
        guard let profiles = file.load() else {
            lastLoadFailed = true
            return []
        }
        lastLoadFailed = false
        return profiles.sorted { $0.sortOrder < $1.sortOrder }
    }

    // Loads first, so the answer does not depend on whether anything has read the file yet.
    var unreadableProfileIds: Set<UUID> {
        _ = loadProfiles()
        return file.unreadableIds
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
        syncJournal.recorded(.credentialProfile, written: SyncRecordChanges.changedIds(from: previous, to: profiles))
        return true
    }

    @discardableResult
    func saveProfilesWithoutSync(_ profiles: [CredentialProfile]) -> Bool {
        guard !lastLoadFailed else {
            Self.logger.warning("Refusing to save credential profiles: the last load failed and this would overwrite them")
            return false
        }
        guard file.save(profiles) else { return false }
        NotificationCenter.default.post(name: .credentialProfilesDidChange, object: nil)
        return true
    }

    @discardableResult
    func addProfile(_ profile: CredentialProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        // A record this build cannot read still owns its id, so a second record under it would replace it on save.
        guard !profiles.contains(where: { $0.id == profile.id }), !file.unreadableIds.contains(profile.id) else {
            Self.logger.error("Refusing to add credential profile \(profile.id.uuidString, privacy: .public): the id is taken")
            return false
        }
        var placed = profile
        placed.sortOrder = (profiles.map { $0.sortOrder }.max() ?? -1) + 1
        profiles.append(placed)
        return saveProfiles(profiles)
    }

    // A name already here is skipped, so a file can never select one of this Mac's credentials by naming it.
    func addImportedProfiles(_ imported: [PlannedCredentialProfile]) -> [BundleRef: UUID]? {
        guard !imported.isEmpty else { return [:] }
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return nil }

        var takenNames = Set(profiles.map { Self.nameKey($0.name) })
        var nextSortOrder = (profiles.map(\.sortOrder).max() ?? -1) + 1
        var created: [BundleRef: UUID] = [:]
        for profile in imported where created[profile.ref] == nil {
            let key = Self.nameKey(profile.name)
            guard !key.isEmpty, takenNames.insert(key).inserted else { continue }
            let added = CredentialProfile(
                name: profile.name,
                username: profile.username,
                // A file never chooses how this Mac finds a password: pgpass would read ~/.pgpass for its host.
                passwordMode: .prompt,
                secureFieldIds: profile.secureFieldIds,
                sortOrder: nextSortOrder
            )
            nextSortOrder += 1
            profiles.append(added)
            created[profile.ref] = added.id
        }

        guard !created.isEmpty else { return [:] }
        guard saveProfiles(profiles) else { return nil }
        return created
    }

    @discardableResult
    func updateProfile(_ profile: CredentialProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        profiles[index] = profile
        guard saveProfiles(profiles) else { return false }
        // Best effort: the connect path resolves the username from the profile either way.
        if !writeUsernameThrough(profile, byUser: true) {
            Self.logger.error(
                "Saved credential profile \(profile.id.uuidString, privacy: .public) but could not update the connections linked to it"
            )
        }
        return true
    }

    // Linked connections take the profile's credentials as their own first; nothing is deleted if that hand-over fails.
    @discardableResult
    func deleteProfile(_ profile: CredentialProfile) -> Bool {
        var profiles = loadProfiles()
        guard !lastLoadFailed else { return false }
        // The stored record, not the caller's copy, which can predate a sync or another window's edit.
        var current = profiles.first { $0.id == profile.id } ?? profile
        current.secureFieldIds = Array(Set(current.secureFieldIds).union(profile.secureFieldIds)).sorted()
        profiles.removeAll { $0.id == profile.id }
        guard unlinkConnections(from: current, byUser: true) else { return false }
        guard saveProfiles(profiles) else { return false }
        syncJournal.recorded(.credentialProfile, deleted: [profile.id.uuidString])

        deleteSecrets(for: current)
        return true
    }

    // connection.username stays filled for a linked connection: the IAM signer, ~/.pgpass, dump flags and sync read it raw.
    @discardableResult
    func writeUsernameThrough(_ profile: CredentialProfile, byUser: Bool) -> Bool {
        let storage = connectionStorageProvider()
        let linked = Set(
            storage.loadConnections()
                .filter { $0.credentialMode == .profile(id: profile.id) }
                .map { $0.id }
        )
        return storage.mutateConnections(ids: linked, byUser: byUser) { connection in
            connection.username = profile.username
        }
    }

    // `byUser` false (a sync pull) never signs connections.json, which may hold a command nobody here approved.
    @discardableResult
    func unlinkConnections(from profile: CredentialProfile, byUser: Bool) -> Bool {
        let storage = connectionStorageProvider()
        // An unreadable library may hold connections that use this profile, and they would be left pointing at nothing.
        guard !storage.isLibraryUnreadable else {
            Self.logger.error(
                "Refusing to unlink from credential profile \(profile.id.uuidString, privacy: .public): the connections could not be read"
            )
            return false
        }
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
        let converted = storage.mutateConnections(ids: Set(linked.map { $0.id }), byUser: byUser) { connection in
            connection.credentialMode = .inline
            connection.username = profile.username
            // Every inline password flag is written, or a stale prompt or pgpass flag overrides the password just copied in.
            connection.promptForPassword = profile.passwordMode == .prompt
            connection.usePgpass = profile.passwordMode == .pgpass
            // connections.json re-stamps itself on a user save, so a source from an untrusted profiles file would become runnable.
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

    @discardableResult
    func savePassword(_ password: String, for profileId: UUID) -> Bool {
        keychain.writeString(password, forKey: Self.passwordKey(profileId))
    }

    func loadPassword(for profileId: UUID) -> String? {
        keychain.readStringResult(forKey: Self.passwordKey(profileId))
            .value(label: Self.passwordLabel(profileId), logger: Self.logger)
    }

    func passwordRead(for profileId: UUID) -> DeferredSecretRead {
        deferredRead(forKey: Self.passwordKey(profileId), label: Self.passwordLabel(profileId))
    }

    func readPassword(for profileId: UUID) -> ProfileSecretRead {
        ProfileSecretRead(keychain.readStringResult(forKey: Self.passwordKey(profileId)))
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
            .value(label: Self.fieldLabel(fieldId, profileId), logger: Self.logger)
    }

    func secureFieldRead(fieldId: String, for profileId: UUID) -> DeferredSecretRead {
        deferredRead(forKey: Self.fieldKey(fieldId, profileId), label: Self.fieldLabel(fieldId, profileId))
    }

    func readSecureField(fieldId: String, for profileId: UUID) -> ProfileSecretRead {
        ProfileSecretRead(keychain.readStringResult(forKey: Self.fieldKey(fieldId, profileId)))
    }

    func deleteSecureField(fieldId: String, for profileId: UUID) {
        keychain.delete(forKey: Self.fieldKey(fieldId, profileId))
    }

    // Every Keychain item this type writes. A key missing here outlives its profile with nothing left to name it.
    func deleteSecrets(for profile: CredentialProfile) {
        deletePassword(for: profile.id)
        for fieldId in profile.secureFieldIds {
            deleteSecureField(fieldId: fieldId, for: profile.id)
        }
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func passwordKey(_ profileId: UUID) -> String {
        "\(secretPrefix)password.\(profileId.uuidString)"
    }

    private static func fieldKey(_ fieldId: String, _ profileId: UUID) -> String {
        "\(secretPrefix)field.\(fieldId).\(profileId.uuidString)"
    }

    private static func passwordLabel(_ profileId: UUID) -> String {
        "Credential profile password (profileId=\(profileId.uuidString))"
    }

    private static func fieldLabel(_ fieldId: String, _ profileId: UUID) -> String {
        "Credential profile field \(fieldId) (profileId=\(profileId.uuidString))"
    }

    private func deferredRead(forKey key: String, label: String) -> DeferredSecretRead {
        let keychain = keychain
        return DeferredSecretRead(key: key, label: label, logger: Self.logger) {
            keychain.readStringResult(forKey: key)
        }
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

    // Nil when anything the profile owns exists but could not be read; prompt, pgpass and source modes own no password.
    private func readSecrets(for profile: CredentialProfile) -> ProfileSecrets? {
        var password: String?
        if profile.passwordMode.usesStoredSecret {
            switch readPassword(for: profile.id) {
            case .found(let value): password = value
            case .absent: break
            case .unreadable: return nil
            }
        }
        var fields: [String: String] = [:]
        for fieldId in profile.secureFieldIds {
            switch readSecureField(fieldId: fieldId, for: profile.id) {
            case .found(let value): fields[fieldId] = value
            case .absent: break
            case .unreadable: return nil
            }
        }
        return ProfileSecrets(password: password, fields: fields)
    }
}
