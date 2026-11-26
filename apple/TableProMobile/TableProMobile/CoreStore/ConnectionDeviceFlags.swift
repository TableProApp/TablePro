import Foundation
import TableProModels

// What the iOS sync keeps about a connection that no core record has a field for, by id. Both are device-local:
// a profile link this device dropped and has not seen the server drop yet, and an SSL require an older iOS build
// stored, which is either the Mac's Preferred or Required until a pull says which.
nonisolated struct ConnectionDeviceFlags: Equatable, Sendable {
    static let profileLinksToClearKey = "com.TablePro.connections.sshProfileLinksToClear"
    static let legacySSLRequireKey = "com.TablePro.connections.legacySSLRequire"

    var profileLinksToClear: Set<UUID> = []
    var legacySSLRequire: Set<UUID> = []

    init(profileLinksToClear: Set<UUID> = [], legacySSLRequire: Set<UUID> = []) {
        self.profileLinksToClear = profileLinksToClear
        self.legacySSLRequire = legacySSLRequire
    }

    init(defaults: UserDefaults) {
        profileLinksToClear = Self.ids(defaults.stringArray(forKey: Self.profileLinksToClearKey))
        legacySSLRequire = Self.ids(defaults.stringArray(forKey: Self.legacySSLRequireKey))
    }

    init(of connections: [DatabaseConnection]) {
        profileLinksToClear = Set(connections.filter(\.clearsSSHProfileLink).map(\.id))
        legacySSLRequire = Set(connections.filter { $0.sslConfiguration?.isLegacyRequire == true }.map(\.id))
    }

    // Ids this build cannot read keep their flags, so a newer build that reads the copy still finds them.
    func keeping(_ kept: Set<UUID>, from stored: ConnectionDeviceFlags) -> ConnectionDeviceFlags {
        ConnectionDeviceFlags(
            profileLinksToClear: profileLinksToClear.union(stored.profileLinksToClear.intersection(kept)),
            legacySSLRequire: legacySSLRequire.union(stored.legacySSLRequire.intersection(kept))
        )
    }

    func save(to defaults: UserDefaults) {
        Self.store(profileLinksToClear, forKey: Self.profileLinksToClearKey, in: defaults)
        Self.store(legacySSLRequire, forKey: Self.legacySSLRequireKey, in: defaults)
    }

    private static func store(_ ids: Set<UUID>, forKey key: String, in defaults: UserDefaults) {
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
        }
    }

    private static func ids(_ strings: [String]?) -> Set<UUID> {
        Set((strings ?? []).compactMap(UUID.init(uuidString:)))
    }
}
