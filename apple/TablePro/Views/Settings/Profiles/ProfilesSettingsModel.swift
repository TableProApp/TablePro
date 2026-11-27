import Combine
import Foundation
import os

enum ProfileNames {
    // Every picker offers a profile by name alone, so a copy never reuses one.
    static func available(basedOn name: String, taken: [String]) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = String(format: String(localized: "%@ (Copy)"), base)
        guard isTaken(first, in: taken) else { return first }
        for index in 2...(taken.count + 2) {
            let candidate = String(format: String(localized: "%1$@ (Copy %2$lld)"), base, Int64(index))
            if !isTaken(candidate, in: taken) { return candidate }
        }
        return first
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines),
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
    }

    private static func isTaken(_ name: String, in taken: [String]) -> Bool {
        taken.contains { matches($0, name) }
    }
}

@MainActor
final class ProfilesSettingsModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ProfilesSettingsModel")

    @Published private(set) var credentialProfiles: [CredentialProfile] = []
    @Published private(set) var sshProfiles: [SSHProfile] = []
    @Published private(set) var usage: [UUID: Int] = [:]
    @Published private(set) var credentialLoadFailed = false
    @Published private(set) var sshLoadFailed = false
    @Published private(set) var unreadableProfileCount = 0
    @Published private(set) var usageUnknown = false
    @Published private(set) var someConnectionsUnreadable = false
    @Published private(set) var isLoaded = false

    private let credentialStorage: CredentialProfileStorage
    private let sshStorage: SSHProfileStorage
    private let connectionStorage: ConnectionStorage
    private var cancellables: Set<AnyCancellable> = []

    init(
        credentialStorage: CredentialProfileStorage = .shared,
        sshStorage: SSHProfileStorage = .shared,
        connectionStorage: ConnectionStorage = .shared,
        appEvents: AppEvents = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.credentialStorage = credentialStorage
        self.sshStorage = sshStorage
        self.connectionStorage = connectionStorage

        // Profiles also change from a connection window and from sync while this pane is on screen.
        notificationCenter.publisher(for: .credentialProfilesDidChange)
            .merge(with: notificationCenter.publisher(for: .sshProfilesDidChange))
            .map { _ in () }
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reloadProfiles() }
            .store(in: &cancellables)
        appEvents.connectionUpdated
            .map { _ in () }
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.recountUsage() }
            .store(in: &cancellables)
    }

    func refresh() {
        reloadProfiles()
        recountUsage()
        if !isLoaded { isLoaded = true }
    }

    func reloadProfiles() {
        let credentials = credentialStorage.loadProfiles()
        let credentialsFailed = credentialStorage.lastLoadFailed
        let unreadable = credentialsFailed ? 0 : credentialStorage.unreadableProfileIds.count
        let ssh = sshStorage.loadProfiles()
        let sshFailed = sshStorage.lastLoadFailed

        // Refresh in place: an unchanged value never publishes, so the list does not redraw on every visit.
        if credentialProfiles != credentials { credentialProfiles = credentials }
        if credentialLoadFailed != credentialsFailed { credentialLoadFailed = credentialsFailed }
        if unreadableProfileCount != unreadable { unreadableProfileCount = unreadable }
        if sshProfiles != ssh { sshProfiles = ssh }
        if sshLoadFailed != sshFailed { sshLoadFailed = sshFailed }
    }

    func recountUsage() {
        let connections = connectionStorage.loadConnections()
        let unknown = connectionStorage.lastLoadFailed
        var counts: [UUID: Int] = [:]
        for connection in connections {
            if let id = connection.credentialMode.profileId {
                counts[id, default: 0] += 1
            }
            if case .profile(let id, _) = connection.sshTunnelMode {
                counts[id, default: 0] += 1
            }
        }
        let unreadable = unknown ? false : !connectionStorage.unreadableConnectionIds.isEmpty

        if usage != counts { usage = counts }
        if usageUnknown != unknown { usageUnknown = unknown }
        if someConnectionsUnreadable != unreadable { someConnectionsUnreadable = unreadable }
    }

    func usageCount(for profileId: UUID) -> Int? {
        usageUnknown ? nil : usage[profileId, default: 0]
    }

    func pendingDeletion(of kind: ProfileKind, id: UUID, name: String) -> PendingProfileDeletion? {
        guard !usageUnknown else { return nil }
        return PendingProfileDeletion.make(kind: kind, id: id, name: name, connectionStorage: connectionStorage)
    }

    func delete(_ pending: PendingProfileDeletion) -> Bool {
        defer { refresh() }
        switch pending.kind {
        case .credential:
            guard let stored = credentialStorage.profile(for: pending.id) else { return !credentialStorage.lastLoadFailed }
            return credentialStorage.deleteProfile(stored)
        case .ssh:
            guard let stored = sshStorage.profile(for: pending.id) else { return !sshStorage.lastLoadFailed }
            return sshStorage.deleteProfile(stored)
        }
    }

    func duplicateCredentialProfile(id: UUID) -> Bool {
        defer { refresh() }
        let profiles = credentialStorage.loadProfiles()
        guard !credentialStorage.lastLoadFailed, let source = profiles.first(where: { $0.id == id }) else { return false }

        // Every secret is read before anything is written, so a locked Keychain leaves no half-made copy.
        var password: String?
        if source.passwordMode.usesStoredSecret {
            switch credentialStorage.readPassword(for: source.id) {
            case .found(let value): password = value
            case .absent: break
            case .unreadable: return false
            }
        }
        var fields: [String: String] = [:]
        for fieldId in source.secureFieldIds {
            switch credentialStorage.readSecureField(fieldId: fieldId, for: source.id) {
            case .found(let value): fields[fieldId] = value
            case .absent: break
            case .unreadable: return false
            }
        }

        let copy = CredentialProfile(
            name: ProfileNames.available(basedOn: source.name, taken: profiles.map(\.name)),
            username: source.username,
            passwordMode: source.passwordMode,
            secureFieldIds: source.secureFieldIds
        )
        guard credentialStorage.addProfile(copy) else { return false }

        var written = true
        if let password {
            written = credentialStorage.savePassword(password, for: copy.id)
        }
        for (fieldId, value) in fields.sorted(by: { $0.key < $1.key }) where written {
            written = credentialStorage.saveSecureField(value, fieldId: fieldId, for: copy.id)
        }
        guard written else {
            Self.logger.error("Removing the copy of credential profile \(id.uuidString, privacy: .public): a secret could not be copied")
            credentialStorage.deleteProfile(copy)
            return false
        }
        return true
    }

    func duplicateSSHProfile(id: UUID) -> Bool {
        defer { refresh() }
        let profiles = sshStorage.loadProfiles()
        guard !sshStorage.lastLoadFailed, let source = profiles.first(where: { $0.id == id }) else { return false }

        var secrets: [SSHSecret: String] = [:]
        for secret in SSHSecret.allCases {
            switch sshStorage.readSecret(secret, for: source.id) {
            case .found(let value): secrets[secret] = value
            case .absent: break
            case .unreadable: return false
            }
        }

        let copy = SSHProfile(
            name: ProfileNames.available(basedOn: source.name, taken: profiles.map(\.name)),
            host: source.host,
            port: source.port,
            username: source.username,
            authMethod: source.authMethod,
            privateKeyPath: source.privateKeyPath,
            agentSocketPath: source.agentSocketPath,
            jumpHosts: source.jumpHosts,
            totpMode: source.totpMode,
            totpAlgorithm: source.totpAlgorithm,
            totpDigits: source.totpDigits,
            totpPeriod: source.totpPeriod
        )
        guard sshStorage.addProfile(copy) else { return false }

        var written = true
        for secret in SSHSecret.allCases where written {
            guard let value = secrets[secret] else { continue }
            written = sshStorage.saveSecret(value, secret, for: copy.id)
        }
        guard written else {
            Self.logger.error("Removing the copy of SSH profile \(id.uuidString, privacy: .public): a secret could not be copied")
            sshStorage.deleteProfile(copy)
            return false
        }
        return true
    }
}
