//
//  SyncStatus.swift
//  TablePro
//
//  Sync state representation
//

import Foundation

/// Current state of the sync system
enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(SyncError)
    case disabled(DisableReason)

    var isSyncing: Bool {
        self == .syncing
    }

    var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        default:
            return true
        }
    }
}

/// Reason why sync is disabled
enum DisableReason: Equatable {
    case noAccount
    case licenseRequired
    case licenseExpired
    case userDisabled
}
