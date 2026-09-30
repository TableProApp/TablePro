//
//  SyncPendingDeletionsTests.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

struct SyncPendingDeletionsTests {
    private static let zoneID = CKRecordZone.ID(
        zoneName: "TableProSync",
        ownerName: CKCurrentUserDefaultName
    )
    private static let uuid = UUID()
    private static let tableFavoriteId = "4f1c2b7e9a0d4c3b8e6f5a2d1c0b9e8f"

    private static var everyCategoryOn: SyncSettings {
        SyncSettings(
            enabled: true,
            syncConnections: true,
            syncGroupsAndTags: true,
            syncSettings: true,
            syncPasswords: true,
            syncSSHProfiles: true,
            syncCredentialProfiles: true,
            syncTableFavorites: true,
            syncDatabaseFavorites: true,
            syncSQLFavorites: true
        )
    }

    private static func settings(_ change: (inout SyncSettings) -> Void) -> SyncSettings {
        var settings = everyCategoryOn
        change(&settings)
        return settings
    }

    private static func deletion(of type: SyncRecordType, id: String = uuid.uuidString) -> [CKRecord.ID] {
        [SyncRecordMapper.recordID(type: type, id: id, in: zoneID)]
    }

    private static var everyAppliedDeletion: [CKRecord.ID] {
        let uuidTypes: [SyncRecordType] = [
            .connection, .group, .tag, .sshProfile, .credentialProfile, .favorite, .favoriteFolder
        ]
        return uuidTypes.flatMap { deletion(of: $0) } + deletion(of: .tableFavorite, id: tableFavoriteId)
    }

    @Test("A connection deleted on another device is withheld while Connections is off")
    func connectionDeletionFollowsItsSwitch() {
        let off = SyncPendingDeletions.parse(
            Self.deletion(of: .connection),
            settings: Self.settings { $0.syncConnections = false }
        )
        let on = SyncPendingDeletions.parse(Self.deletion(of: .connection), settings: Self.everyCategoryOn)

        #expect(off.connections.isEmpty)
        #expect(on.connections == [Self.uuid])
    }

    @Test("A group deleted on another device is withheld while Groups and Tags is off")
    func groupDeletionFollowsItsSwitch() {
        let off = SyncPendingDeletions.parse(
            Self.deletion(of: .group),
            settings: Self.settings { $0.syncGroupsAndTags = false }
        )
        let on = SyncPendingDeletions.parse(Self.deletion(of: .group), settings: Self.everyCategoryOn)

        #expect(off.groups.isEmpty)
        #expect(on.groups == [Self.uuid])
    }

    @Test("A tag deleted on another device is withheld while Groups and Tags is off")
    func tagDeletionFollowsItsSwitch() {
        let off = SyncPendingDeletions.parse(
            Self.deletion(of: .tag),
            settings: Self.settings { $0.syncGroupsAndTags = false }
        )
        let on = SyncPendingDeletions.parse(Self.deletion(of: .tag), settings: Self.everyCategoryOn)

        #expect(off.tags.isEmpty)
        #expect(on.tags == [Self.uuid])
    }

    @Test("An SSH profile deleted on another device is withheld while SSH Profiles is off")
    func sshProfileDeletionFollowsItsSwitch() {
        let off = SyncPendingDeletions.parse(
            Self.deletion(of: .sshProfile),
            settings: Self.settings { $0.syncSSHProfiles = false }
        )
        let on = SyncPendingDeletions.parse(Self.deletion(of: .sshProfile), settings: Self.everyCategoryOn)

        #expect(off.sshProfiles.isEmpty)
        #expect(on.sshProfiles == [Self.uuid])
    }

    @Test("A credential profile deleted on another device is withheld while Credential Profiles is off")
    func credentialProfileDeletionFollowsItsSwitch() {
        let off = SyncPendingDeletions.parse(
            Self.deletion(of: .credentialProfile),
            settings: Self.settings { $0.syncCredentialProfiles = false }
        )
        let on = SyncPendingDeletions.parse(Self.deletion(of: .credentialProfile), settings: Self.everyCategoryOn)

        #expect(off.credentialProfiles.isEmpty)
        #expect(on.credentialProfiles == [Self.uuid])
    }

    @Test("A table favorite deleted on another device is withheld while Table Favorites is off")
    func tableFavoriteDeletionFollowsItsSwitch() {
        let deletion = Self.deletion(of: .tableFavorite, id: Self.tableFavoriteId)
        let off = SyncPendingDeletions.parse(deletion, settings: Self.settings { $0.syncTableFavorites = false })
        let on = SyncPendingDeletions.parse(deletion, settings: Self.everyCategoryOn)

        #expect(off.tableFavorites.isEmpty)
        #expect(on.tableFavorites == [Self.tableFavoriteId])
    }

    @Test("A saved query or folder deleted on another device is withheld while Saved Queries is off")
    func sqlFavoriteDeletionFollowsItsSwitch() {
        let deletions = Self.deletion(of: .favorite) + Self.deletion(of: .favoriteFolder)
        let off = SyncPendingDeletions.parse(deletions, settings: Self.settings { $0.syncSQLFavorites = false })
        let on = SyncPendingDeletions.parse(deletions, settings: Self.everyCategoryOn)

        #expect(off.sqlFavorites.isEmpty)
        #expect(off.sqlFolders.isEmpty)
        #expect(on.sqlFavorites == [Self.uuid])
        #expect(on.sqlFolders == [Self.uuid])
    }

    @Test("A database favorite or column layout deleted on another device is withheld while its category is off")
    func databaseFavoriteAndLayoutDeletionsFollowTheirSwitches() {
        let layoutCategory = "columnLayout.\(Self.uuid.uuidString).shop.public.orders"
        let deletions = Self.deletion(of: .favoriteDatabase, id: Self.tableFavoriteId)
            + Self.deletion(of: .settings, id: layoutCategory)
        let off = SyncPendingDeletions.parse(deletions, settings: Self.settings {
            $0.syncDatabaseFavorites = false
            $0.syncSettings = false
        })
        let on = SyncPendingDeletions.parse(deletions, settings: Self.everyCategoryOn)

        #expect(off == SyncPendingDeletions())
        #expect(on.databaseFavorites == [Self.tableFavoriteId])
        #expect(on.settingsRecordNames == [SyncRecordType.settings.recordName(for: layoutCategory)])
    }

    @Test("A category switched off withholds its own deletions and no other")
    func switchedOffCategoryLeavesOthersApplied() {
        let pending = SyncPendingDeletions.parse(
            Self.everyAppliedDeletion,
            settings: Self.settings { $0.syncConnections = false }
        )

        #expect(pending.connections.isEmpty)
        #expect(pending.groups == [Self.uuid])
        #expect(pending.tags == [Self.uuid])
        #expect(pending.sshProfiles == [Self.uuid])
        #expect(pending.credentialProfiles == [Self.uuid])
        #expect(pending.tableFavorites == [Self.tableFavoriteId])
        #expect(pending.sqlFavorites == [Self.uuid])
        #expect(pending.sqlFolders == [Self.uuid])
    }

    @Test("Each category switch withholds exactly its own record types")
    func eachSwitchWithholdsItsOwnRecordTypes() {
        let switches: [(WritableKeyPath<SyncSettings, Bool>, Set<SyncRecordType>)] = [
            (\.syncConnections, [.connection]),
            (\.syncGroupsAndTags, [.group, .tag]),
            (\.syncSettings, [.settings]),
            (\.syncPasswords, []),
            (\.syncSSHProfiles, [.sshProfile]),
            (\.syncCredentialProfiles, [.credentialProfile]),
            (\.syncTableFavorites, [.tableFavorite]),
            (\.syncDatabaseFavorites, [.favoriteDatabase]),
            (\.syncSQLFavorites, [.favorite, .favoriteFolder])
        ]

        #expect(SyncRecordType.allCases.allSatisfy { Self.everyCategoryOn.syncs($0) })
        for (keyPath, governed) in switches {
            let settings = Self.settings { $0[keyPath: keyPath] = false }
            let withheld = Set(SyncRecordType.allCases.filter { !settings.syncs($0) })
            #expect(withheld == governed, "\(keyPath)")
        }
        #expect(Set(switches.flatMap { $0.1 }) == Set(SyncRecordType.allCases))
    }

    @Test("Every category switched off applies no remote deletion")
    func everyCategoryOffAppliesNothing() {
        let pending = SyncPendingDeletions.parse(
            Self.everyAppliedDeletion,
            settings: Self.settings {
                $0.syncConnections = false
                $0.syncGroupsAndTags = false
                $0.syncSSHProfiles = false
                $0.syncCredentialProfiles = false
                $0.syncTableFavorites = false
                $0.syncSQLFavorites = false
            }
        )

        #expect(pending == SyncPendingDeletions())
    }
}
