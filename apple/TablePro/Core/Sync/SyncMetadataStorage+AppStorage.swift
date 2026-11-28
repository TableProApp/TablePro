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

    var themeSeedState: ThemeSeedState? {
        get { userDefaults.string(forKey: Self.themeSeedKey).flatMap(ThemeSeedState.init(rawValue:)) }
        set { userDefaults.set(newValue?.rawValue, forKey: Self.themeSeedKey) }
    }
}
