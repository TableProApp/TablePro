//
//  SyncMetadataStorage+AppStorage.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

internal enum ThemeSeedState: String {
    case pending
    case done
}

internal extension SyncMetadataStorage {
    static let appDefault = SyncMetadataStorage(userDefaults: AppStorageEnvironment.shared.defaults)

    private static let themeSeedKey = "com.TablePro.sync.themeSeed"

    private static let projectMembershipSeededKey = "com.TablePro.sync.projectMembershipSeeded"

    // Set once, on the first run of a build that can write a project and its membership.
    var projectMembershipSeeded: Bool {
        get { userDefaults.bool(forKey: Self.projectMembershipSeededKey) }
        set { userDefaults.set(newValue, forKey: Self.projectMembershipSeededKey) }
    }

    var themeSeedState: ThemeSeedState? {
        get { userDefaults.string(forKey: Self.themeSeedKey).flatMap(ThemeSeedState.init(rawValue:)) }
        set { userDefaults.set(newValue?.rawValue, forKey: Self.themeSeedKey) }
    }
}
