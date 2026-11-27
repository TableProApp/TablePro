import Foundation

// The two iOS sync flags an earlier build kept by id in UserDefaults: a profile link this device dropped and has not
// seen the server drop yet, and an SSL require an older iOS build stored, which is either the Mac's Preferred or Required
// until a pull says which. The core's record now holds both as device members (`DeviceSettingsRecord`); these keys are
// read once to move them there, then removed.
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

    var isEmpty: Bool {
        profileLinksToClear.isEmpty && legacySSLRequire.isEmpty
    }

    static func forget(in defaults: UserDefaults) {
        defaults.removeObject(forKey: profileLinksToClearKey)
        defaults.removeObject(forKey: legacySSLRequireKey)
    }

    private static func ids(_ strings: [String]?) -> Set<UUID> {
        Set((strings ?? []).compactMap(UUID.init(uuidString:)))
    }
}
