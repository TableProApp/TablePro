//
//  LegacyLibraryMirror.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

// The library in the stores the previous stable reads: connections.json, the groups, the tags and the favourites
// order. The core holds the library; these stay in step with it until that build runs the core (ADR 0010).
@MainActor
final class LegacyLibraryMirror {
    struct Contents {
        var connections: [DatabaseConnection]
        var groups: [ConnectionGroup]
        var tags: [ConnectionTag]
        var favoritesOrder: [UUID]
        var projects: [ConnectionProject]
        var sshProfiles: [SSHProfile]
        var credentialProfiles: [CredentialProfile]
    }

    // What the last complete write left in each store, so a launch can tell which side another build changed.
    struct Record: Codable, Equatable {
        var legacy: String
        var core: String
        // A connections.json gone since then was deleted by hand; the previous stable never removes it.
        var connectionsFileExisted: Bool
        // The core's store took a write these stores did not, so the next launch writes them again.
        var legacyBehind: Bool
    }

    static let groupsKey = "com.TablePro.groups"
    static let tagsKey = "com.TablePro.tags"
    static let projectsKey = "com.TablePro.projects"
    static let sshProfilesKey = "com.TablePro.sshProfiles"
    static let recordKey = "com.TablePro.library.mirrorRecord"
    static let profilesInCoreKey = "com.TablePro.library.profilesInCore"

    private static let logger = Logger(subsystem: "com.TablePro", category: "LegacyLibraryMirror")

    let file: IntegrityStampedFileStore<StoredConnection>
    // Its own tag, which no save of a profile ever vouches for: a profile can name a command to run.
    let profilesFile: IntegrityStampedFileStore<CredentialProfile>
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL, defaults: UserDefaults, integrity: ConnectionStoreIntegrity, logger: Logger) {
        self.file = IntegrityStampedFileStore(
            fileURL: fileURL,
            label: "connections.json",
            logger: logger,
            userSaveEstablishesTrust: true,
            integrity: integrity
        )
        self.profilesFile = IntegrityStampedFileStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("credentialProfiles.json"),
            label: "credentialProfiles.json",
            logger: logger,
            userSaveEstablishesTrust: false,
            integrity: integrity
        )
        self.defaults = defaults
    }

    var isTrusted: Bool { file.isTrusted }
    var profilesTrusted: Bool { profilesFile.isTrusted }
    var unreadableIds: Set<UUID> { file.unreadableIds }
    var unreadableProfileIds: Set<UUID> { profilesFile.unreadableIds }
    var holdsConnectionsFile: Bool { FileManager.default.fileExists(atPath: file.fileURL.path) }

    // Set once the core holds the profiles: until then only the previous stable's stores did.
    var profilesInCore: Bool {
        get { defaults.bool(forKey: Self.profilesInCoreKey) }
        set { defaults.set(newValue, forKey: Self.profilesInCoreKey) }
    }

    var record: Record? {
        get { defaults.data(forKey: Self.recordKey).flatMap { try? decoder.decode(Record.self, from: $0) } }
        set {
            if let newValue, let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: Self.recordKey)
            } else {
                defaults.removeObject(forKey: Self.recordKey)
            }
        }
    }

    // Nil when one of the stores holds something no decoding can read; the library then stays as the core has it.
    func read() -> Contents? {
        guard let stored = file.load() else { return nil }
        guard let credentialProfiles = profilesFile.load() else { return unreadable("credential profiles") }
        var groups: [ConnectionGroup] = []
        var tags = ConnectionTag.presets
        if let data = defaults.data(forKey: Self.groupsKey) {
            guard let decoded = Self.salvaged(data, SalvagedGroup.self, \.group) else { return unreadable("groups") }
            groups = decoded
        }
        if let data = defaults.data(forKey: Self.tagsKey) {
            guard let decoded = Self.salvaged(data, SalvagedTag.self, \.tag) else { return unreadable("tags") }
            tags = decoded
        }
        var projects: [ConnectionProject] = []
        if let data = defaults.data(forKey: Self.projectsKey) {
            guard let decoded = Self.salvaged(data, SalvagedProject.self, \.project) else { return unreadable("projects") }
            projects = decoded
        }
        var sshProfiles: [SSHProfile] = []
        if let data = defaults.data(forKey: Self.sshProfilesKey) {
            guard let decoded = Self.salvaged(data, SalvagedSSHProfile.self, \.profile) else { return unreadable("SSH profiles") }
            sshProfiles = decoded
        }
        let order = (defaults.stringArray(forKey: PreferenceKeys.connectionListFavoritesOrder.name) ?? [])
            .compactMap(UUID.init(uuidString:))
        return Contents(
            connections: stored.map { $0.toConnection() },
            groups: groups,
            tags: tags,
            favoritesOrder: order,
            projects: projects,
            sshProfiles: sshProfiles,
            credentialProfiles: credentialProfiles.sorted { $0.sortOrder < $1.sortOrder }
        )
    }

    private func unreadable(_ store: String) -> Contents? {
        Self.logger.error("The saved \(store, privacy: .public) could not be read; the library is left as it is")
        return nil
    }

    // False when connections.json or credentialProfiles.json was not written; the defaults it writes after them cannot
    // fail. `connectionsWritten` runs after connections.json, so a record can name the half-written stores this build left.
    func write(
        _ contents: Contents,
        byUser: Bool,
        removingSecrets: Bool,
        removingUnreadable removedIds: Set<UUID>,
        connectionsWritten: () -> Void
    ) -> Bool {
        guard file.save(
            contents.connections.map { StoredConnection(from: $0) },
            byUser: byUser,
            removingSecrets: removingSecrets,
            removingUnreadable: removedIds
        ) else {
            return false
        }
        connectionsWritten()
        guard profilesFile.save(contents.credentialProfiles, byUser: false, removingSecrets: removingSecrets) else {
            return false
        }
        do {
            defaults.set(try encoder.encode(contents.groups), forKey: Self.groupsKey)
            defaults.set(try encoder.encode(contents.tags), forKey: Self.tagsKey)
            defaults.set(try encoder.encode(contents.projects), forKey: Self.projectsKey)
            defaults.set(try encoder.encode(contents.sshProfiles), forKey: Self.sshProfilesKey)
        } catch {
            Self.logger.error("Could not encode the groups or tags: \(error.publicLogShape, privacy: .public)")
            return false
        }
        defaults.set(contents.favoritesOrder.map(\.uuidString), forKey: PreferenceKeys.connectionListFavoritesOrder.name)
        return true
    }

    // Of the stores as they are now. A store that is absent reads differently from an empty one.
    func digest() -> String {
        var hasher = SHA256()
        func add(_ data: Data?) {
            guard let data else {
                hasher.update(data: Data([0]))
                return
            }
            hasher.update(data: Data([1]) + withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) })
            hasher.update(data: data)
        }
        add(try? Data(contentsOf: file.fileURL))
        add(defaults.data(forKey: Self.groupsKey))
        add(defaults.data(forKey: Self.tagsKey))
        add(defaults.data(forKey: Self.projectsKey))
        add(try? Data(contentsOf: profilesFile.fileURL))
        add(defaults.data(forKey: Self.sshProfilesKey))
        add(defaults.stringArray(forKey: PreferenceKeys.connectionListFavoritesOrder.name).map {
            Data($0.joined(separator: ",").utf8)
        })
        return Self.hex(hasher.finalize())
    }

    static func digest(of data: Data?) -> String {
        guard let data else { return "" }
        return hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // An entry that does not decode costs that entry; a payload that is not a list at all is nil.
    private static func salvaged<Salvage: Decodable, Element: Decodable>(
        _ data: Data,
        _ salvage: Salvage.Type,
        _ element: KeyPath<Salvage, Element?>
    ) -> [Element]? {
        if let decoded = try? JSONDecoder().decode([Element].self, from: data) {
            return decoded
        }
        return (try? JSONDecoder().decode([Salvage].self, from: data))?.compactMap { $0[keyPath: element] }
    }
}

private struct SalvagedGroup: Decodable {
    let group: ConnectionGroup?

    init(from decoder: Decoder) throws {
        group = try? ConnectionGroup(from: decoder)
    }
}

private struct SalvagedSSHProfile: Decodable {
    let profile: SSHProfile?

    init(from decoder: Decoder) throws {
        profile = try? SSHProfile(from: decoder)
    }
}

private struct SalvagedProject: Decodable {
    let project: ConnectionProject?

    init(from decoder: Decoder) throws {
        project = try? ConnectionProject(from: decoder)
    }
}

private struct SalvagedTag: Decodable {
    let tag: ConnectionTag?

    init(from decoder: Decoder) throws {
        tag = try? ConnectionTag(from: decoder)
    }
}
