//
//  SyncMetadataStorage+AppStorage.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

internal extension SyncMetadataStorage {
    static let appDefault = SyncMetadataStorage(userDefaults: AppStorageEnvironment.shared.defaults)
}
