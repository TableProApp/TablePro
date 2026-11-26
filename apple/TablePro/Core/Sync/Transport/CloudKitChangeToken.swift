//
//  CloudKitChangeToken.swift
//  TablePro
//

import CloudKit
import Foundation

nonisolated enum CloudKitChangeToken {
    // The form `SyncMetadataStorage` keeps, so the token the Swift engine saved is the engine's first one.
    static func archive(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
