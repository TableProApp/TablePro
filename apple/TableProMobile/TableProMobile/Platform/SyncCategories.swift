import Foundation
import TableProFFI

// What this device syncs, whichever provider carries it. Every switch but Passwords starts on, as on the Mac. The
// kinds an iPhone does not show, such as table favorites, stay on so the Mac's own come back unchanged.
nonisolated struct SyncCategories: Equatable, Sendable {
    static let connectionsKey = "com.TablePro.settings.syncConnections"
    static let groupsAndTagsKey = "com.TablePro.settings.syncGroupsAndTags"
    static let sshProfilesKey = "com.TablePro.settings.syncSSHProfiles"
    static let savedQueriesKey = "com.TablePro.settings.syncSavedQueries"

    var connections = true
    var passwords = false
    var groupsAndTags = true
    var sshProfiles = true
    var savedQueries = true

    init(
        connections: Bool = true,
        passwords: Bool = false,
        groupsAndTags: Bool = true,
        sshProfiles: Bool = true,
        savedQueries: Bool = true
    ) {
        self.connections = connections
        self.passwords = passwords
        self.groupsAndTags = groupsAndTags
        self.sshProfiles = sshProfiles
        self.savedQueries = savedQueries
    }

    init(defaults: UserDefaults) {
        connections = defaults.object(forKey: Self.connectionsKey) as? Bool ?? true
        passwords = defaults.bool(forKey: AppPreferences.syncPasswordsKey)
        groupsAndTags = defaults.object(forKey: Self.groupsAndTagsKey) as? Bool ?? true
        sshProfiles = defaults.object(forKey: Self.sshProfilesKey) as? Bool ?? true
        savedQueries = defaults.object(forKey: Self.savedQueriesKey) as? Bool ?? true
    }

    func store(in defaults: UserDefaults) {
        defaults.set(connections, forKey: Self.connectionsKey)
        defaults.set(passwords, forKey: AppPreferences.syncPasswordsKey)
        defaults.set(groupsAndTags, forKey: Self.groupsAndTagsKey)
        defaults.set(sshProfiles, forKey: Self.sshProfilesKey)
        defaults.set(savedQueries, forKey: Self.savedQueriesKey)
    }

    // Passwords ride on their connections, so they stop with them.
    var syncsPasswords: Bool {
        connections && passwords
    }

    // By the wire names the Mac's categories use (SyncProviderCoordinator.categories).
    var coreArgument: SyncCategoriesArg {
        var off: [String] = []
        if !connections {
            off += ["connection", "connection_project"]
        }
        if !groupsAndTags {
            off += ["group", "tag"]
        }
        if !sshProfiles {
            off.append("ssh_profile")
        }
        if !savedQueries {
            off += ["saved_query", "saved_query_folder"]
        }
        return SyncCategoriesArg(offKinds: off, passwords: syncsPasswords)
    }
}
