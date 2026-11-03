import Foundation

public enum SyncStatusAction: Hashable, Sendable, Identifiable {
    case tryAgain
    case manageStorage
    case openAccountSettings
    case checkForUpdates
    case uploadAgain
    case turnOffSync

    public var id: Self { self }

    public var title: String {
        switch self {
        case .tryAgain:
            String(localized: "Try Again")
        case .manageStorage:
            String(localized: "Manage Storage…")
        case .openAccountSettings:
            String(localized: "Open System Settings…")
        case .checkForUpdates:
            String(localized: "Check for Updates…")
        case .uploadAgain:
            String(localized: "Upload Again")
        case .turnOffSync:
            String(localized: "Turn Off iCloud Sync")
        }
    }
}

// Both apps render this, so a sync state has one title, one symbol and one set of actions. The
// sentence that names the device and the handlers stay with each app.
public struct SyncStatusPresentation: Equatable, Sendable {
    public let status: SyncStatus

    public init(status: SyncStatus) {
        self.status = status
    }

    public init(_ error: SyncError) {
        self.init(status: .error(error))
    }

    public var blocker: SyncBlocker? {
        status.error?.blocker
    }

    public var isWarning: Bool {
        status.error != nil
    }

    // Every symbol here ships with macOS 13 and iOS 17.
    public var symbolName: String {
        switch status {
        case .idle:
            "checkmark.icloud"
        case .syncing:
            "arrow.triangle.2.circlepath"
        case .error(.blocked(.signedOut)), .error(.offline), .disabled:
            "icloud.slash"
        case .error(.blocked(.accountRestricted)), .error(.blocked(.unavailable)):
            "xmark.icloud"
        case .error:
            "exclamationmark.icloud"
        }
    }

    public var title: String {
        switch status {
        case .idle:
            String(localized: "Up to Date")
        case .syncing:
            String(localized: "Syncing…")
        case .error(.blocked(let blocker)):
            Self.title(for: blocker)
        case .error(.offline):
            String(localized: "Offline")
        case .error(.busy):
            String(localized: "Waiting to Retry")
        case .error(.recordsRejected):
            String(localized: "Some Changes Not Uploaded")
        case .error(.pullNotSaved):
            String(localized: "Changes Not Saved")
        case .error(.unexpected):
            String(localized: "Sync Failed")
        case .disabled:
            String(localized: "Sync Off")
        }
    }

    // Try Again only where another attempt can succeed without anything else changing first.
    public var actions: [SyncStatusAction] {
        switch status {
        case .idle, .syncing, .disabled:
            []
        case .error(.blocked(let blocker)):
            Self.actions(for: blocker)
        case .error(.offline), .error(.busy), .error(.recordsRejected), .error(.pullNotSaved), .error(.unexpected):
            [.tryAgain]
        }
    }

    private static func title(for blocker: SyncBlocker) -> String {
        switch blocker {
        case .storageFull:
            String(localized: "iCloud Storage Is Full")
        case .signedOut:
            String(localized: "Not Signed In to iCloud")
        case .accountNotReady:
            String(localized: "iCloud Is Not Ready")
        case .accountRestricted:
            String(localized: "iCloud Is Restricted")
        case .dataDeletedFromICloud:
            String(localized: "TablePro Data Was Removed from iCloud")
        case .appUpdateRequired:
            String(localized: "Update Required")
        case .unavailable:
            String(localized: "Sync Is Unavailable")
        }
    }

    // Uploading again after the data was removed is the person's call (Apple's guidance), so it
    // is offered beside turning sync off, never retried on its own.
    private static func actions(for blocker: SyncBlocker) -> [SyncStatusAction] {
        switch blocker {
        case .storageFull:
            [.manageStorage, .tryAgain]
        case .signedOut:
            [.openAccountSettings, .tryAgain]
        case .accountNotReady:
            [.tryAgain]
        case .dataDeletedFromICloud:
            [.uploadAgain, .turnOffSync]
        case .appUpdateRequired:
            [.checkForUpdates]
        case .accountRestricted, .unavailable:
            []
        }
    }
}
